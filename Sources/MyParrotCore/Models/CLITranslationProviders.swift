import Foundation
import os

/// #2612 TRL-02／05:Claude CLI 翻譯後端。配方沿 `ClaudeCLIRunner`(CORR-13 鎖死),只換提示詞與 schema。
public struct ClaudeCLITranslationProvider: TranslationProvider {
    public let executable: URL
    public var model: String?
    public var timeout: TimeInterval
    public var target: TranslationTarget

    public init(executable: URL, model: String? = nil, timeout: TimeInterval = TranslationPlan.timeout, target: TranslationTarget) {
        self.executable = executable
        self.model = (model?.isEmpty == false) ? model : nil
        self.timeout = timeout
        self.target = target
    }

    public static func arguments(userPrompt: String, systemPrompt: String, model: String?) -> [String] {
        ClaudeCLIRunner.arguments(userPrompt: userPrompt, systemPrompt: systemPrompt, schema: TranslationPrompt.schema, model: model)
    }

    public func translate(_ lines: [String], from: Locale.Language, to: Locale.Language) async throws -> TranslationResult {
        let user = TranslationPrompt.user(lines: lines, to: target)
        let system = TranslationPrompt.system(to: target)
        let args = Self.arguments(userPrompt: user, systemPrompt: system, model: model)
        let out = await ClaudeCLIRunner.runInTemporaryDirectory(executable: executable, arguments: args,
                                                                prefix: "myparrot-translate-", timeout: timeout)
        if out.timedOut { throw TranslationError.timeout }
        if let e = out.launchError { throw TranslationError.failed(-1, e) }
        return try Self.parseOutput(out.stdout, exitCode: out.exitCode, stderr: out.stderr, expected: lines.count)
    }

    /// 只認最後一行 JSON;未登入 ⇒ `.notLoggedIn`;`is_error` ⇒ `.failed`;`structured_output.lines` 長度要對。
    public static func parseOutput(_ stdout: String, exitCode: Int32, stderr: String = "", expected: Int) throws -> TranslationResult {
        if ClaudeCLIRunner.looksNotLoggedIn(stdout: stdout, stderr: stderr) { throw TranslationError.notLoggedIn }
        guard let obj = ClaudeCLIRunner.lastJSONObject(in: stdout) else {
            if exitCode != 0 { throw TranslationError.failed(exitCode, "沒有 JSON 回應") }
            throw TranslationError.badOutput("沒有 JSON 回應")
        }
        if let isErr = obj["is_error"] as? Bool, isErr { throw TranslationError.failed(exitCode, "CLI 回報錯誤") }
        guard let so = obj["structured_output"] as? [String: Any] else { throw TranslationError.badOutput("缺 structured_output") }
        let lines = try TranslationPrompt.parseLines(so, expected: expected)
        let u = ClaudeCLIRunner.usage(obj)
        return TranslationResult(lines: lines, inputTokens: u.input, outputTokens: u.output, durationMs: u.durationMs)
    }
}

/// #2612 TRL-02／05:Codex CLI 翻譯後端。配方沿 `CodexCLIRunner`(CDX-04 鎖死)。
public struct CodexCLITranslationProvider: TranslationProvider {
    public let executable: URL
    public var model: String?
    public var timeout: TimeInterval
    public var target: TranslationTarget

    public init(executable: URL, model: String? = nil, timeout: TimeInterval = TranslationPlan.timeout, target: TranslationTarget) {
        self.executable = executable
        self.model = (model?.isEmpty == false) ? model : nil
        self.timeout = timeout
        self.target = target
    }

    public func translate(_ lines: [String], from: Locale.Language, to: Locale.Language) async throws -> TranslationResult {
        let user = TranslationPrompt.user(lines: lines, to: target)
        let system = TranslationPrompt.system(to: target)
        let out = await CodexCLIRunner.runInTemporaryDirectory(executable: executable, systemPrompt: system, userPrompt: user,
                                                               schema: TranslationPrompt.schema, model: model,
                                                               prefix: "myparrot-codex-translate-", timeout: timeout)
        if out.timedOut { throw TranslationError.timeout }
        if let e = out.launchError { throw TranslationError.failed(-1, e) }
        let tools = CodexCLIRunner.toolActivityCount(in: out.stdout)
        if tools > 0 { os_log("MyParrot codex: translate 回合出現 %ld 則非訊息 item(唯讀沙箱)", tools) }
        return try Self.parseOutput(lastMessage: out.lastMessage, stdout: out.stdout, exitCode: out.exitCode,
                                    stderr: out.stderr, expected: lines.count, durationMs: out.durationMs)
    }

    public static func parseOutput(lastMessage: String?, stdout: String, exitCode: Int32, stderr: String = "",
                                   expected: Int, durationMs: Int = 0) throws -> TranslationResult {
        if CodexCLIRunner.looksNotLoggedIn(exitCode: exitCode, stdout: stdout, stderr: stderr) { throw TranslationError.codexNotLoggedIn }
        if exitCode != 0 { throw TranslationError.failed(exitCode, "CLI 回報錯誤") }
        guard let obj = CodexCLIRunner.finalJSONObject(lastMessage: lastMessage, stdout: stdout) else {
            throw TranslationError.badOutput("沒有 JSON 回應")
        }
        let lines = try TranslationPrompt.parseLines(obj, expected: expected)
        let u = CodexCLIRunner.usage(in: stdout)
        return TranslationResult(lines: lines, inputTokens: u.input, outputTokens: u.output, durationMs: durationMs)
    }
}
