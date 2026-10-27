import Testing
import Foundation
@testable import MyParrotCore

/// #2418 真路徑(鐵則 3,但不需要真 CLI):把 `codex` 換成假腳本,把收到的參數、工作目錄、工作目錄裡的檔、stdin、PATH 原樣落檔,
/// 並把 `--output-schema` 指到的檔複製出來、把最終 JSON 寫進 `-o` 指到的檔——逐欄驗 CDX-04(呼叫被鎖住)與 CDX-05(送出資料範圍)。
@Suite("CDX 假 codex 腳本")
struct CodexCLITests {

    /// 假 codex:落檔參數／cwd／cwd 檔案清單／stdin／PATH,複製 schema,寫 -o,吐三則 JSONL。`final` 是寫進 -o 的 JSON。
    private func makeFakeCodex(in dump: URL, final: String) throws -> URL {
        let script = dump.appendingPathComponent("codex")
        let body = """
        #!/bin/sh
        printf '%s\\0' "$@" > "\(dump.path)/args.txt"
        pwd > "\(dump.path)/cwd.txt"
        cat > "\(dump.path)/stdin.txt"
        printf '%s' "$PATH" > "\(dump.path)/path.txt"
        ls -1 > "\(dump.path)/cwdfiles.txt"
        OUT=""; SCHEMA=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "-o" ]; then OUT="$a"; fi
          if [ "$prev" = "--output-schema" ]; then SCHEMA="$a"; fi
          prev="$a"
        done
        cp "$SCHEMA" "\(dump.path)/schema-copy.json"
        printf '%s' '\(final)' > "$OUT"
        touch stray-file-in-cwd
        echo '{"type":"thread.started","thread_id":"t"}'
        echo '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"NOT-USED-WHEN-O-FILE-EXISTS"}}'
        echo '{"type":"turn.completed","usage":{"input_tokens":13000,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":2}}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// `printf '%s\0' "$@"` 每個參數後面都接 NUL ⇒ split 會多一個尾端空字串,去掉它(提示詞是真的最後一個參數)。
    private func readArgs(_ dump: URL) throws -> [String] {
        var a = try String(contentsOf: dump.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        if a.last == "" { a.removeLast() }
        return a
    }

    @Test("CDX-04/05 校正:參數鎖定、提示詞只含段落、schema 檔＝CorrectionPrompt.schema、暫存夾即刪、stdin 為空") func fakeCodexCorrection() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakecodex_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        let script = try makeFakeCodex(in: dump, final: #"{"corrections":[{"segment":1,"original":"竹子稿","suggestion":"逐字稿","reason":"r"},{"segment":0,"original":"不在原文","suggestion":"x","reason":"invalid"}]}"#)

        let provider = CodexCLIProvider(executable: script, model: nil, timeout: 20)
        let segments = ["/Users/someone/會議名稱 2026-10-23.m4a 不該出現", "我們今天要討論竹子稿的格式"]
        let result = try await provider.suggest(segments: segments, range: 1..<2, language: .zhTW)

        // 解析:-o 檔優先(JSONL 那則 NOT-USED 不該被用);usage 來自 turn.completed
        #expect(result.suggestions.count == 2)
        #expect(result.inputTokens == 13500 && result.outputTokens == 42)
        #expect(result.durationMs > 0)

        // CDX-04:參數逐項
        let args = try readArgs(dump)
        #expect(args.first == "exec")
        let joined = args.joined(separator: " ")
        for need in ["--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox read-only",
                     "--color never", "--json", "--output-schema", "-o"] {
            #expect(joined.contains(need), "缺 \(need)")
        }
        for bad in CodexCLIProvider.forbiddenFlags { #expect(!args.contains(bad), "配方含禁用字 \(bad)") }
        #expect(!joined.contains("-m "), "沒填 model 不該帶 -m")
        let path = try String(contentsOf: dump.appendingPathComponent("path.txt"), encoding: .utf8)
        #expect(path.split(separator: ":").map(String.init).contains(dump.path), "子行程 PATH 要含 CLI 自己的目錄")

        // CDX-05:提示詞(最後一個參數)只含批次內的段落;批次外那段(含路徑/檔名/會議名)不得出現;字串＝CorrectionPrompt 合成
        let prompt = args.last ?? ""
        #expect(prompt.contains("1: 我們今天要討論竹子稿的格式"))
        #expect(!prompt.contains("/Users") && !prompt.contains(".m4a") && !prompt.contains("會議名稱"))
        let expectedPrompt = CodexCLIRunner.composePrompt(systemPrompt: CorrectionPrompt.system(for: .zhTW),
                                                          userPrompt: CorrectionPrompt.user(segments: segments, range: 1..<2, language: .zhTW))
        #expect(prompt == expectedPrompt, "提示詞應與 Claude 後端同一份字串(系統提示＋使用者訊息)")
        // schema 檔內容＝CorrectionPrompt.schema(與 Claude 後端 --json-schema 同一份)
        let schemaCopy = try String(contentsOf: dump.appendingPathComponent("schema-copy.json"), encoding: .utf8)
        #expect(schemaCopy == CorrectionPrompt.schema)
        // schema 與 -o 都在工作目錄裡(呼叫當下只有 schema.json)
        let cwdFiles = try String(contentsOf: dump.appendingPathComponent("cwdfiles.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(cwdFiles == ["schema.json"], "呼叫當下工作目錄只該有 schema.json,得 \(cwdFiles)")
        if let i = args.firstIndex(of: "--output-schema") { #expect(args[i + 1].hasSuffix("/schema.json")) }
        if let i = args.firstIndex(of: "-o") { #expect(args[i + 1].hasSuffix("/last.json")) }

        // 工作目錄是暫存夾、呼叫後已刪(連 stray 檔與 last.json);stdin 為空
        let cwd = try String(contentsOf: dump.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("myparrot-codex-correction-"))
        #expect(!FileManager.default.fileExists(atPath: cwd), "暫存夾應在呼叫後刪掉")
        let stdin = try String(contentsOf: dump.appendingPathComponent("stdin.txt"), encoding: .utf8)
        #expect(stdin.isEmpty)
    }

    @Test("CDX-04/05 會議記錄:三段提示詞、-m 帶檔位、schema 檔＝MinutesPrompt.schema、帳目帶過") func fakeCodexMinutes() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakecodexmin_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        let script = try makeFakeCodex(in: dump, final: #"{"summary":"預算凍結","decisions":["用 B 案"],"actions":["週五前交安全章"],"questions":[],"timeline":["0:00:05 討論預算"]}"#)

        let previous = MinutesDocument(summary: "舊摘要", decisions: ["舊決議"], transcriptLinesConsumed: 3)
        let input = MinutesInput(previous: previous, transcriptDelta: ["對方 0:00:05: 今天討論預算", "你 0:00:09: 好"],
                                 notes: "# 週會\n- 重點一", language: .zhTW)
        let provider = CodexCLIMinutesProvider(executable: script, model: "tier-x", timeout: 20)
        let doc = try await provider.update(input)
        #expect(doc.summary == "預算凍結" && doc.decisions == ["用 B 案"] && doc.actions.count == 1 && doc.timeline.count == 1)
        #expect(doc.inputTokens == 13500 && doc.outputTokens == 42)
        #expect(doc.transcriptLinesConsumed == 3, "previous 的行數帳目要原樣帶過去")

        let args = try readArgs(dump)
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-m tier-x"))
        for bad in CodexCLIMinutesProvider.forbiddenFlags { #expect(!args.contains(bad)) }
        let prompt = args.last ?? ""
        #expect(prompt.contains("舊摘要") && prompt.contains("舊決議"))
        #expect(prompt.contains("對方 0:00:05: 今天討論預算") && prompt.contains("你 0:00:09: 好") && prompt.contains("重點一"))
        #expect(!prompt.contains("transcriptLinesConsumed") && !prompt.contains("updatedAt"))
        #expect(!prompt.contains("/Users") && !prompt.contains(".m4a") && !prompt.contains(dump.path))
        #expect(prompt == CodexCLIRunner.composePrompt(systemPrompt: MinutesPrompt.system(for: .zhTW), userPrompt: MinutesPrompt.user(input)))
        let schemaCopy = try String(contentsOf: dump.appendingPathComponent("schema-copy.json"), encoding: .utf8)
        #expect(schemaCopy == MinutesPrompt.schema)
        let cwd = try String(contentsOf: dump.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("myparrot-codex-minutes-") && !FileManager.default.fileExists(atPath: cwd))
    }

    @Test("CDX-09 假 codex 回未登入/逾時/非零,訊息不含原始輸出") func fakeCodexFailures() async throws {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_fakecodex_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dump) }
        func make(_ name: String, _ body: String) throws -> URL {
            let u = dump.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            return u
        }
        let notLoggedIn = try make("c1", "echo 'Not logged in. Run codex login' >&2; exit 1")
        await #expect(throws: CorrectionError.codexNotLoggedIn) {
            _ = try await CodexCLIProvider(executable: notLoggedIn, timeout: 20).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
        }
        await #expect(throws: MinutesError.codexNotLoggedIn) {
            _ = try await CodexCLIMinutesProvider(executable: notLoggedIn, timeout: 20).update(MinutesInput(transcriptDelta: ["a"], notes: ""))
        }
        let slow = try make("c2", "sleep 30; echo '{}'")
        await #expect(throws: CorrectionError.timeout) {
            _ = try await CodexCLIProvider(executable: slow, timeout: 1).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
        }
        let crash = try make("c3", "echo 'SECRET-DIAGNOSTIC-LINE' >&2; exit 3")
        do {
            _ = try await CodexCLIProvider(executable: crash, timeout: 20).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
            Issue.record("非零退出沒丟錯")
        } catch let e as CorrectionError {
            #expect(!e.zhTW.contains("SECRET-DIAGNOSTIC-LINE"), "錯誤訊息不得含 CLI 原始輸出")
            if case .failed(let code, _) = e { #expect(code == 3) } else { Issue.record("型別應為 failed,得 \(e)") }
        }
        // exit 0 但 -o 沒寫、stdout 也沒 agent_message ⇒ badOutput
        let silent = try make("c4", "echo '{\"type\":\"turn.started\"}'; exit 0")
        do {
            _ = try await CodexCLIProvider(executable: silent, timeout: 20).suggest(segments: ["a"], range: 0..<1, language: .zhTW)
            Issue.record("沒有 JSON 回應沒丟錯")
        } catch let e as CorrectionError {
            if case .badOutput = e {} else { Issue.record("型別應為 badOutput,得 \(e)") }
        }
    }
}
