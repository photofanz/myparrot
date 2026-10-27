import Testing
import Foundation
@testable import MyParrotCore

/// #2612 TRL-05／10 真路徑(鐵則 3,但不需要真 CLI):假 `claude`／`codex` 腳本把收到的參數落檔,逐欄驗提示詞只有編號＋行文字、
/// schema、配方旗標;失敗三型訊息不含原始輸出;行數不符整批作廢。
@Suite("TRL 假 claude／codex 腳本")
struct TranslationCLITests {

    private func makeDump() throws -> URL {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_faketrl_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        return dump
    }

    private func makeScript(_ dump: URL, name: String, body: String) throws -> URL {
        let u = dump.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    private func readArgs(_ dump: URL) throws -> [String] {
        var a = try String(contentsOf: dump.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        if a.last == "" { a.removeLast() }
        return a
    }

    @Test("TRL-05 Claude:提示詞只有編號＋行文字、schema＝lines、配方旗標、剝編號") func fakeClaude() async throws {
        let dump = try makeDump()
        defer { try? FileManager.default.removeItem(at: dump) }
        let script = try makeScript(dump, name: "claude", body: """
        printf '%s\\0' "$@" > "\(dump.path)/args.txt"
        pwd > "\(dump.path)/cwd.txt"
        echo '{"type":"result","structured_output":{"lines":["1: 我們開始。","2: 誰負責後續?"]},"usage":{"input_tokens":1,"cache_creation_input_tokens":1700,"output_tokens":60},"duration_ms":4100,"permission_denials":[]}'
        """)
        let p = ClaudeCLITranslationProvider(executable: script, model: "tier-x", timeout: 20, target: .zhHant)
        let lines = ["Let's start.", "Who owns the follow-up?"]
        let r = try await p.translate(lines, from: Locale.Language(identifier: "en-US"), to: TranslationTarget.zhHant.language)
        #expect(r.lines == ["我們開始。", "誰負責後續?"])
        #expect(r.inputTokens == 1701 && r.outputTokens == 60 && r.durationMs == 4100)

        let args = try readArgs(dump)
        #expect(args.first == "-p")
        let joined = args.joined(separator: " ")
        for need in ["--output-format json", "--json-schema", "--setting-sources", "--system-prompt", "--tools StructuredOutput",
                     "--max-turns 1", "--no-session-persistence", "--strict-mcp-config", "--model tier-x"] {
            #expect(joined.contains(need), "缺 \(need)")
        }
        if let i = args.firstIndex(of: "--json-schema") { #expect(args[i + 1] == TranslationPrompt.schema) }
        for bad in ClaudeCLIRunner.forbiddenFlags { #expect(!args.contains(bad)) }
        // TRL-05:提示詞＝TranslationPrompt.user 原樣;只有編號＋行文字＋目標語言
        let prompt = args[1]
        #expect(prompt == TranslationPrompt.user(lines: lines, to: .zhHant))
        #expect(prompt.contains("1: Let's start.") && prompt.contains("2: Who owns the follow-up?"))
        for bad in ["你", "對方", "You:", "Them:", "0:00:", ".m4a", "/Users", "會議名稱"] { #expect(!prompt.contains(bad), "提示詞不該含 \(bad)") }
        if let i = args.firstIndex(of: "--system-prompt") { #expect(args[i + 1].contains("Traditional Chinese (Taiwan)")) }
        // 正控:把講者標籤塞進行文字的版本必須被同一條斷言抓到(手動把 lines[0] 改成「你: Let's start.」驗過一次)
        let cwd = try String(contentsOf: dump.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("myparrot-translate-") && !FileManager.default.fileExists(atPath: cwd))
    }

    @Test("TRL-05 Codex:schema 檔＝TranslationPrompt.schema、提示詞＝系統＋使用者、-o 優先") func fakeCodex() async throws {
        let dump = try makeDump()
        defer { try? FileManager.default.removeItem(at: dump) }
        let script = try makeScript(dump, name: "codex", body: """
        printf '%s\\0' "$@" > "\(dump.path)/args.txt"
        OUT=""; SCHEMA=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "-o" ]; then OUT="$a"; fi
          if [ "$prev" = "--output-schema" ]; then SCHEMA="$a"; fi
          prev="$a"
        done
        cp "$SCHEMA" "\(dump.path)/schema-copy.json"
        printf '%s' '{"lines":["甲","乙"]}' > "$OUT"
        echo '{"type":"turn.completed","usage":{"input_tokens":13600,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":2}}'
        """)
        let p = CodexCLITranslationProvider(executable: script, model: nil, timeout: 20, target: .ja)
        let lines = ["A", "B"]
        let r = try await p.translate(lines, from: Locale.Language(identifier: "en-US"), to: TranslationTarget.ja.language)
        #expect(r.lines == ["甲", "乙"] && r.inputTokens == 13600 && r.outputTokens == 42)
        let args = try readArgs(dump)
        #expect(args.first == "exec")
        for bad in CodexCLIRunner.forbiddenFlags { #expect(!args.contains(bad)) }
        let schemaCopy = try String(contentsOf: dump.appendingPathComponent("schema-copy.json"), encoding: .utf8)
        #expect(schemaCopy == TranslationPrompt.schema)
        let prompt = args.last ?? ""
        #expect(prompt == CodexCLIRunner.composePrompt(systemPrompt: TranslationPrompt.system(to: .ja), userPrompt: TranslationPrompt.user(lines: lines, to: .ja)))
        #expect(prompt.contains("Japanese") && !prompt.contains("/Users"))
    }

    @Test("TRL-10 失敗三型＋行數不符整批作廢,訊息不含原始輸出") func failures() async throws {
        let dump = try makeDump()
        defer { try? FileManager.default.removeItem(at: dump) }
        let from = Locale.Language(identifier: "en-US"), to = TranslationTarget.zhHant.language
        let notLoggedIn = try makeScript(dump, name: "c1", body: "echo 'Not logged in · Please run /login'; exit 1")
        await #expect(throws: TranslationError.notLoggedIn) {
            _ = try await ClaudeCLITranslationProvider(executable: notLoggedIn, timeout: 20, target: .zhHant).translate(["a"], from: from, to: to)
        }
        let slow = try makeScript(dump, name: "c2", body: "sleep 30; echo '{}'")
        await #expect(throws: TranslationError.timeout) {
            _ = try await ClaudeCLITranslationProvider(executable: slow, timeout: 1, target: .zhHant).translate(["a"], from: from, to: to)
        }
        let crash = try makeScript(dump, name: "c3", body: "echo 'SECRET-DIAGNOSTIC-LINE' >&2; exit 3")
        do {
            _ = try await ClaudeCLITranslationProvider(executable: crash, timeout: 20, target: .zhHant).translate(["a"], from: from, to: to)
            Issue.record("非零退出沒丟錯")
        } catch let e as TranslationError {
            #expect(!"\(e)".contains("SECRET-DIAGNOSTIC-LINE"))
            if case .failed(let code, _) = e { #expect(code == 3) } else { Issue.record("型別應為 failed,得 \(e)") }
        }
        let short = try makeScript(dump, name: "c4", body: #"echo '{"type":"result","structured_output":{"lines":["只有一行"]},"usage":{}}'"#)
        do {
            _ = try await ClaudeCLITranslationProvider(executable: short, timeout: 20, target: .zhHant).translate(["a", "b"], from: from, to: to)
            Issue.record("行數不符沒丟")
        } catch let e as TranslationError {
            if case .badOutput(let m) = e { #expect(m.contains("行數")) } else { Issue.record("型別應為 badOutput,得 \(e)") }
        }
        let codexNotLoggedIn = try makeScript(dump, name: "x1", body: "echo 'Not logged in. Run codex login' >&2; exit 1")
        await #expect(throws: TranslationError.codexNotLoggedIn) {
            _ = try await CodexCLITranslationProvider(executable: codexNotLoggedIn, timeout: 20, target: .zhHant).translate(["a"], from: from, to: to)
        }
    }
}
