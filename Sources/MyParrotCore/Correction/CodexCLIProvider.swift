import Foundation
import os

/// 校正層第三個後端(#2418 CDX;Eric 2026-10-23 21:50 A1):spawn **本機的 `codex` CLI**,用使用者自己的 ChatGPT 訂閱登入,
/// app 不持任何金鑰。呼叫配方住在 `CodexCLIRunner`(與會議記錄後端共用);提示詞與 schema **重用** `CorrectionPrompt`
/// (與 Claude 後端同一份字串,CDX-05),這裡只剩解析。
public struct CodexCLIProvider: CorrectionProvider {
    public let executable: URL
    public var model: String?
    public var timeout: TimeInterval

    public init(executable: URL, model: String? = nil, timeout: TimeInterval = 60) {
        self.executable = executable
        self.model = (model?.isEmpty == false) ? model : nil
        self.timeout = timeout
    }

    public static func locate(environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        CodexCLIRunner.locate(environmentPath: environmentPath)
    }

    public static func isLoggedIn(executable: URL) async -> Bool {
        await CodexCLIRunner.isLoggedIn(executable: executable)
    }

    public static var forbiddenFlags: Set<String> { CodexCLIRunner.forbiddenFlags }

    // MARK: - 呼叫

    public func suggest(segments: [String], range: Range<Int>, language: TranscriptionLanguage) async throws -> CorrectionResult {
        let user = CorrectionPrompt.user(segments: segments, range: range, language: language)
        let system = CorrectionPrompt.system(for: language)
        let out = await CodexCLIRunner.runInTemporaryDirectory(executable: executable, systemPrompt: system, userPrompt: user,
                                                               schema: CorrectionPrompt.schema, model: model,
                                                               prefix: "myparrot-codex-correction-", timeout: timeout)
        if out.timedOut { throw CorrectionError.timeout }
        if let e = out.launchError { throw CorrectionError.failed(-1, e) }
        let tools = CodexCLIRunner.toolActivityCount(in: out.stdout)
        if tools > 0 { os_log("MyParrot codex: correction 回合出現 %ld 則非訊息 item(唯讀沙箱)", tools) }
        return try Self.parseOutput(lastMessage: out.lastMessage, stdout: out.stdout, exitCode: out.exitCode,
                                    stderr: out.stderr, durationMs: out.durationMs)
    }

    // MARK: - 解析(純函式,CDX-07)

    /// 未登入(非 0 退出＋字樣)⇒ `.codexNotLoggedIn`;非 0 ⇒ `.failed`;`-o` 檔優先、退回 JSONL 的 agent_message;
    /// 缺 `corrections` ⇒ `.badOutput`。訊息只給一句摘要,**不含**原始輸出全文(CORR-09 同款)。
    public static func parseOutput(lastMessage: String?, stdout: String, exitCode: Int32, stderr: String = "",
                                   durationMs: Int = 0) throws -> CorrectionResult {
        if CodexCLIRunner.looksNotLoggedIn(exitCode: exitCode, stdout: stdout, stderr: stderr) { throw CorrectionError.codexNotLoggedIn }
        if exitCode != 0 { throw CorrectionError.failed(exitCode, "CLI 回報錯誤") }
        guard let obj = CodexCLIRunner.finalJSONObject(lastMessage: lastMessage, stdout: stdout) else {
            throw CorrectionError.badOutput("沒有 JSON 回應")
        }
        guard let arr = obj["corrections"] as? [[String: Any]] else {
            throw CorrectionError.badOutput("缺欄位 corrections")
        }
        let suggestions: [CorrectionSuggestion] = arr.compactMap { c in
            guard let seg = c["segment"] as? Int, let o = c["original"] as? String,
                  let s = c["suggestion"] as? String else { return nil }
            return CorrectionSuggestion(segment: seg, original: o, suggestion: s, reason: (c["reason"] as? String) ?? "")
        }
        let u = CodexCLIRunner.usage(in: stdout)
        return CorrectionResult(suggestions: suggestions, inputTokens: u.input, outputTokens: u.output, durationMs: durationMs)
    }
}
