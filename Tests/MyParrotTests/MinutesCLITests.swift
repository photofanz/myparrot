import Testing
import Foundation
@testable import MyParrotCore

/// #2438 Phase 2 真路徑(鐵則 3,但不需要真 CLI):把 `claude` 換成假腳本,把收到的參數、工作目錄、stdin 原樣落檔,
/// 逐欄驗 MIN-01(配方鎖死)與 MIN-02(送出資料範圍);失敗三型(MIN-05)訊息不含原始輸出。
@Suite("MIN 假 claude 腳本")
struct MinutesCLITests {

    @Test("MIN-01/02 參數鎖定、提示詞三段、暫存夾即刪、stdin 為空") func fakeCLI() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakemin_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        let script = dump.appendingPathComponent("claude")
        let body = """
        #!/bin/sh
        printf '%s\\0' "$@" > "\(dump.path)/args.txt"
        pwd > "\(dump.path)/cwd.txt"
        cat > "\(dump.path)/stdin.txt"
        touch stray-file-in-cwd
        echo '{"type":"result","structured_output":{"summary":"預算凍結","decisions":["用 B 案"],"actions":["週五前交安全章"],"questions":[],"timeline":["0:00:05 討論預算"]},"usage":{"input_tokens":1,"cache_creation_input_tokens":4000,"output_tokens":300},"duration_ms":7,"permission_denials":[]}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let previous = MinutesDocument(summary: "舊摘要", decisions: ["舊決議"], transcriptLinesConsumed: 3)
        let input = MinutesInput(previous: previous, transcriptDelta: ["對方 0:00:05: 今天討論預算", "你 0:00:09: 好"],
                                 notes: "# 週會\n- 重點一", language: .zhTW)
        let provider = ClaudeCLIMinutesProvider(executable: script, model: "tier-x", timeout: 20)
        let doc = try await provider.update(input)
        #expect(doc.summary == "預算凍結" && doc.decisions == ["用 B 案"] && doc.actions.count == 1 && doc.timeline.count == 1)
        #expect(doc.inputTokens == 4001 && doc.outputTokens == 300)
        #expect(doc.transcriptLinesConsumed == 3, "previous 的行數帳目要原樣帶過去(由呼叫端更新)")

        // MIN-01:參數逐項
        let args = try String(contentsOf: dump.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        #expect(args.first == "-p")
        let joined = args.joined(separator: " ")
        for need in ["--output-format json", "--json-schema", "--setting-sources", "--system-prompt", "--tools StructuredOutput",
                     "--max-turns 1", "--no-session-persistence", "--strict-mcp-config", "--model tier-x"] {
            #expect(joined.contains(need), "缺 \(need)")
        }
        if let i = args.firstIndex(of: "--json-schema") { #expect(args[i + 1] == MinutesPrompt.schema) }
        if let i = args.firstIndex(of: "--setting-sources") { #expect(args[i + 1] == "") }
        for bad in ClaudeCLIMinutesProvider.forbiddenFlags { #expect(!joined.contains(bad)) }

        // MIN-02:提示詞只有三段;上一版只送五格、新行、筆記;沒有路徑/檔名/本機帳目
        let prompt = args[1]
        #expect(prompt.contains("舊摘要") && prompt.contains("舊決議"))
        #expect(prompt.contains("對方 0:00:05: 今天討論預算") && prompt.contains("你 0:00:09: 好"))
        #expect(prompt.contains("重點一"))
        #expect(!prompt.contains("transcriptLinesConsumed") && !prompt.contains("updatedAt"))
        #expect(!prompt.contains("/Users") && !prompt.contains(".m4a") && !prompt.contains(dump.path))

        // 工作目錄＝暫存夾、呼叫後已刪(連 stray 檔);stdin 為空
        let cwd = try String(contentsOf: dump.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("myparrot-minutes-"))
        #expect(!FileManager.default.fileExists(atPath: cwd))
        let stdin = try String(contentsOf: dump.appendingPathComponent("stdin.txt"), encoding: .utf8)
        #expect(stdin.isEmpty)
    }

    @Test("MIN-05 假 CLI 回未登入/逾時/非零,訊息不含原始輸出") func fakeCLIFailures() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakemin_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        func make(_ name: String, _ body: String) throws -> URL {
            let u = dump.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            return u
        }
        let input = MinutesInput(transcriptDelta: ["a"], notes: "")
        let notLoggedIn = try make("c1", "echo 'Not logged in · Please run /login'; exit 1")
        await #expect(throws: MinutesError.notLoggedIn) {
            _ = try await ClaudeCLIMinutesProvider(executable: notLoggedIn, timeout: 20).update(input)
        }
        let slow = try make("c2", "sleep 30; echo '{}'")
        await #expect(throws: MinutesError.timeout) {
            _ = try await ClaudeCLIMinutesProvider(executable: slow, timeout: 1).update(input)
        }
        let crash = try make("c3", "echo 'SECRET-DIAGNOSTIC-LINE' >&2; exit 3")
        do {
            _ = try await ClaudeCLIMinutesProvider(executable: crash, timeout: 20).update(input)
            Issue.record("非零退出沒丟錯")
        } catch let e as MinutesError {
            #expect(!"\(e)".contains("SECRET-DIAGNOSTIC-LINE"), "錯誤不得含 CLI 原始輸出")
            if case .failed(let code, _) = e { #expect(code == 3) } else { Issue.record("型別應為 failed,得 \(e)") }
        }
    }
}
