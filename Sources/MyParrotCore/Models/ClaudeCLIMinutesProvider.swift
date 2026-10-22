import Foundation

/// 會議記錄失敗的原因(MIN-05)。訊息只給一句摘要,**不含** CLI 原始輸出全文;介面文字由 App 層對應 `L()`。
public enum MinutesError: Error, Sendable, Equatable {
    case cliNotFound
    case notLoggedIn
    case timeout
    case badOutput(String)      // 一句摘要
    case failed(Int32, String)  // exit code + 一句摘要
}

/// #2438 Phase 2 第一個真後端(F3:Claude CLI 先上):spawn 本機 `claude`,配方與校正層共用 `ClaudeCLIRunner`
/// (MIN-01),提示詞與 schema 在 `MinutesPrompt`(MIN-02／03)。逾時預設 120 秒(輸出約 1k tokens,比校正長)。
public struct ClaudeCLIMinutesProvider: MinutesProvider {
    public let executable: URL
    public var model: String?
    public var timeout: TimeInterval

    public init(executable: URL, model: String? = nil, timeout: TimeInterval = 120) {
        self.executable = executable
        self.model = (model?.isEmpty == false) ? model : nil
        self.timeout = timeout
    }

    public static func arguments(userPrompt: String, systemPrompt: String, model: String?) -> [String] {
        ClaudeCLIRunner.arguments(userPrompt: userPrompt, systemPrompt: systemPrompt, schema: MinutesPrompt.schema, model: model)
    }

    public static var forbiddenFlags: Set<String> { ClaudeCLIRunner.forbiddenFlags }

    public func update(_ input: MinutesInput) async throws -> MinutesDocument {
        let user = MinutesPrompt.user(input)
        let system = MinutesPrompt.system(for: input.language)
        let args = Self.arguments(userPrompt: user, systemPrompt: system, model: model)
        let out = await ClaudeCLIRunner.runInTemporaryDirectory(executable: executable, arguments: args,
                                                                prefix: "myparrot-minutes-", timeout: timeout)
        if out.timedOut { throw MinutesError.timeout }
        if let e = out.launchError { throw MinutesError.failed(-1, e) }
        return try Self.parseOutput(out.stdout, exitCode: out.exitCode, stderr: out.stderr, previous: input.previous)
    }

    /// 只認最後一行 JSON;`structured_output` 五格缺一不可、型別要對。`previous` 的本機帳目(吃到的行數)原樣帶過去,
    /// 由呼叫端更新;tokens 取 `usage`;`updatedAt` 可注入(測試)。
    public static func parseOutput(_ stdout: String, exitCode: Int32, stderr: String = "",
                                   previous: MinutesDocument? = nil, now: Date = Date()) throws -> MinutesDocument {
        if ClaudeCLIRunner.looksNotLoggedIn(stdout: stdout, stderr: stderr) { throw MinutesError.notLoggedIn }
        guard let obj = ClaudeCLIRunner.lastJSONObject(in: stdout) else {
            if exitCode != 0 { throw MinutesError.failed(exitCode, "沒有 JSON 回應") }
            throw MinutesError.badOutput("沒有 JSON 回應")
        }
        if let isErr = obj["is_error"] as? Bool, isErr { throw MinutesError.failed(exitCode, "CLI 回報錯誤") }
        guard let so = obj["structured_output"] as? [String: Any] else { throw MinutesError.badOutput("缺 structured_output") }
        guard let summary = so["summary"] as? String else { throw MinutesError.badOutput("缺欄位 summary") }
        func list(_ key: String) throws -> [String] {
            guard let raw = so[key] as? [Any] else { throw MinutesError.badOutput("缺欄位 \(key)") }
            return try raw.map { item in
                guard let s = item as? String else { throw MinutesError.badOutput("欄位 \(key) 型別錯") }
                return s
            }
        }
        let u = ClaudeCLIRunner.usage(obj)
        return MinutesDocument(summary: summary, decisions: try list("decisions"), actions: try list("actions"),
                               questions: try list("questions"), timeline: try list("timeline"),
                               updatedAt: now, inputTokens: u.input, outputTokens: u.output,
                               transcriptLinesConsumed: previous?.transcriptLinesConsumed ?? 0)
    }
}
