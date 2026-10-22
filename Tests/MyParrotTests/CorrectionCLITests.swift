import Testing
import Foundation
@testable import MyParrotCore

/// #2417 真路徑(鐵則 3,但不需要真 CLI):把 `claude` 換成一支假腳本,把收到的參數、
/// 工作目錄、stdin 原樣落檔,逐欄驗 CORR-06(資料範圍)與 CORR-13(呼叫被鎖住)。
@Suite("CORR 假 claude 腳本")
struct CorrectionCLITests {

    @Test("CORR-06/13 參數鎖定、提示詞只含段落、空暫存夾、stdin 為空") func fakeCLI() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakecli_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        let script = dump.appendingPathComponent("claude")
        let body = """
        #!/bin/sh
        printf '%s\\0' "$@" > "\(dump.path)/args.txt"
        pwd > "\(dump.path)/cwd.txt"
        cat > "\(dump.path)/stdin.txt"
        printf '%s' "$PATH" > "\(dump.path)/path.txt"
        touch stray-file-in-cwd
        echo '{"type":"result","structured_output":{"corrections":[{"segment":1,"original":"竹子稿","suggestion":"逐字稿","reason":"r"},{"segment":0,"original":"不在原文","suggestion":"x","reason":"invalid"}]},"usage":{"input_tokens":1,"cache_creation_input_tokens":1500,"output_tokens":20},"duration_ms":5,"permission_denials":[]}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let provider = ClaudeCLIProvider(executable: script, model: nil, timeout: 20)
        let segments = ["/Users/someone/會議名稱 2026-10-17.m4a 不該出現", "我們今天要討論竹子稿的格式"]
        let result = try await provider.suggest(segments: segments, range: 1..<2, language: .zhTW)

        // 解析:兩則都回來(驗證是呼叫端的事),usage 有算
        #expect(result.suggestions.count == 2)
        #expect(result.inputTokens == 1501 && result.outputTokens == 20 && result.durationMs == 5)

        // CORR-13:參數逐項
        let args = try String(contentsOf: dump.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        #expect(args.first == "-p")
        let joined = args.joined(separator: " ")
        for need in ["--output-format json", "--json-schema", "--setting-sources", "--system-prompt", "--tools StructuredOutput", "--max-turns 1", "--no-session-persistence", "--strict-mcp-config"] {
            #expect(joined.contains(need), "缺 \(need)")
        }
        if let i = args.firstIndex(of: "--setting-sources") { #expect(args[i + 1] == "") }
        #expect(!joined.contains("--bare"))
        #expect(joined.contains("--strict-mcp-config"), "沒帶 --strict-mcp-config:MCP 伺服器會把脈絡灌到 50k~150k")
        let path = try String(contentsOf: dump.appendingPathComponent("path.txt"), encoding: .utf8)
        #expect(path.split(separator: ":").map(String.init).contains(dump.path), "子行程 PATH 要含 CLI 自己的目錄")

        // CORR-06:提示詞只含批次內的段落,批次外那段(含路徑/檔名)不得出現
        let prompt = args[1]
        #expect(prompt.contains("1: 我們今天要討論竹子稿的格式"))
        #expect(!prompt.contains("/Users"))
        #expect(!prompt.contains(".m4a"))
        #expect(!prompt.contains("會議名稱"))
        // 正對照:提示詞若真的含了路徑,上面那行 #expect 會抓到(手動把 range 改 0..<2 驗過一次)

        // CORR-13:工作目錄是暫存夾、呼叫後已刪;stdin 為空
        let cwd = try String(contentsOf: dump.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("myparrot-correction-"))
        #expect(!FileManager.default.fileExists(atPath: cwd), "暫存夾應在呼叫後刪掉(連裡面的 stray 檔)")
        let stdin = try String(contentsOf: dump.appendingPathComponent("stdin.txt"), encoding: .utf8)
        #expect(stdin.isEmpty)
    }

    @Test("CORR-09 假 CLI 回未登入/逾時/非零") func fakeCLIFailures() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakecli_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        func make(_ name: String, _ body: String) throws -> URL {
            let u = dump.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            return u
        }
        let notLoggedIn = try make("c1", "echo 'Not logged in · Please run /login'; exit 1")
        await #expect(throws: CorrectionError.notLoggedIn) {
            _ = try await ClaudeCLIProvider(executable: notLoggedIn, timeout: 20).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
        }
        let slow = try make("c2", "sleep 30; echo '{}'")
        await #expect(throws: CorrectionError.timeout) {
            _ = try await ClaudeCLIProvider(executable: slow, timeout: 1).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
        }
        let crash = try make("c3", "echo 'SECRET-DIAGNOSTIC-LINE' >&2; exit 3")
        do {
            _ = try await ClaudeCLIProvider(executable: crash, timeout: 20).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
            Issue.record("非零退出沒丟錯")
        } catch let e as CorrectionError {
            #expect(!e.zhTW.contains("SECRET-DIAGNOSTIC-LINE"), "錯誤訊息不得含 CLI 原始輸出")
        }
    }
}
