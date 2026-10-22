import Foundation

/// 校正層第一個後端(#2417,Eric 2026-10-17 A1):spawn **本機的 `claude` CLI**,用使用者
/// 自己的訂閱登入,app 不持任何金鑰。呼叫配方(CORR-13)自 #2438 Phase 2 起住在
/// `ClaudeCLIRunner`,與會議記錄後端共用一份;這裡只剩校正專屬的提示詞、schema 與解析。
public struct ClaudeCLIProvider: CorrectionProvider {
    public let executable: URL
    public var model: String?
    public var timeout: TimeInterval

    public init(executable: URL, model: String? = nil, timeout: TimeInterval = 60) {
        self.executable = executable
        self.model = (model?.isEmpty == false) ? model : nil
        self.timeout = timeout
    }

    // MARK: - 找 CLI(CORR-05;轉呼叫 runner,呼叫端不用改)

    public static func locate(environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        ClaudeCLIRunner.locate(environmentPath: environmentPath)
    }

    public static func isLoggedIn(executable: URL) async -> Bool {
        await ClaudeCLIRunner.isLoggedIn(executable: executable)
    }

    // MARK: - 參數(純函式,CORR-13 的靜態斷言對象)

    public static func arguments(userPrompt: String, systemPrompt: String, model: String?) -> [String] {
        ClaudeCLIRunner.arguments(userPrompt: userPrompt, systemPrompt: systemPrompt, schema: CorrectionPrompt.schema, model: model)
    }

    /// CORR-13:這幾個旗標一出現就是配方被改壞。
    public static var forbiddenFlags: Set<String> { ClaudeCLIRunner.forbiddenFlags }

    // MARK: - 呼叫

    public func suggest(segments: [String], range: Range<Int>, language: TranscriptionLanguage) async throws -> CorrectionResult {
        let user = CorrectionPrompt.user(segments: segments, range: range, language: language)
        let system = CorrectionPrompt.system(for: language)
        let args = Self.arguments(userPrompt: user, systemPrompt: system, model: model)
        let out = await ClaudeCLIRunner.runInTemporaryDirectory(executable: executable, arguments: args,
                                                                prefix: "myparrot-correction-", timeout: timeout)
        if out.timedOut { throw CorrectionError.timeout }
        if let e = out.launchError { throw CorrectionError.failed(-1, e) }
        return try Self.parseOutput(out.stdout, exitCode: out.exitCode, stderr: out.stderr)
    }

    // MARK: - 解析(純函式)

    /// 只認最後一行 JSON;`result` 含 "Not logged in" ⇒ `.notLoggedIn`;非 0 且沒 JSON ⇒ `.failed`。
    /// 訊息只給一句摘要,**不含**原始輸出全文(CORR-09)。
    public static func parseOutput(_ stdout: String, exitCode: Int32, stderr: String = "") throws -> CorrectionResult {
        if ClaudeCLIRunner.looksNotLoggedIn(stdout: stdout, stderr: stderr) { throw CorrectionError.notLoggedIn }
        guard let obj = ClaudeCLIRunner.lastJSONObject(in: stdout) else {
            if exitCode != 0 { throw CorrectionError.failed(exitCode, "沒有 JSON 回應") }
            throw CorrectionError.badOutput("沒有 JSON 回應")
        }
        if let isErr = obj["is_error"] as? Bool, isErr {
            throw CorrectionError.failed(exitCode, "CLI 回報錯誤")
        }
        guard let so = obj["structured_output"] as? [String: Any],
              let arr = so["corrections"] as? [[String: Any]] else {
            throw CorrectionError.badOutput("缺 structured_output.corrections")
        }
        let suggestions: [CorrectionSuggestion] = arr.compactMap { c in
            guard let seg = c["segment"] as? Int, let o = c["original"] as? String,
                  let s = c["suggestion"] as? String else { return nil }
            return CorrectionSuggestion(segment: seg, original: o, suggestion: s, reason: (c["reason"] as? String) ?? "")
        }
        let u = ClaudeCLIRunner.usage(obj)
        return CorrectionResult(suggestions: suggestions, inputTokens: u.input, outputTokens: u.output, durationMs: u.durationMs)
    }
}
