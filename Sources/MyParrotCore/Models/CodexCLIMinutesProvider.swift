import Foundation
import os

/// #2418 CDX:會議記錄第三個後端。spawn 本機 `codex`,配方與校正層共用 `CodexCLIRunner`,提示詞與 schema 重用 `MinutesPrompt`
/// (與 Claude 後端同一份字串,CDX-05)。逾時預設 120 秒(與 Claude 後端同)。
public struct CodexCLIMinutesProvider: MinutesProvider {
    public let executable: URL
    public var model: String?
    public var timeout: TimeInterval

    public init(executable: URL, model: String? = nil, timeout: TimeInterval = 120) {
        self.executable = executable
        self.model = (model?.isEmpty == false) ? model : nil
        self.timeout = timeout
    }

    public static var forbiddenFlags: Set<String> { CodexCLIRunner.forbiddenFlags }

    public func update(_ input: MinutesInput) async throws -> MinutesDocument {
        let user = MinutesPrompt.user(input)
        let system = MinutesPrompt.system(for: input.language)
        let out = await CodexCLIRunner.runInTemporaryDirectory(executable: executable, systemPrompt: system, userPrompt: user,
                                                               schema: MinutesPrompt.schema, model: model,
                                                               prefix: "myparrot-codex-minutes-", timeout: timeout)
        if out.timedOut { throw MinutesError.timeout }
        if let e = out.launchError { throw MinutesError.failed(-1, e) }
        let tools = CodexCLIRunner.toolActivityCount(in: out.stdout)
        if tools > 0 { os_log("MyParrot codex: minutes 回合出現 %ld 則非訊息 item(唯讀沙箱)", tools) }
        return try Self.parseOutput(lastMessage: out.lastMessage, stdout: out.stdout, exitCode: out.exitCode,
                                    stderr: out.stderr, previous: input.previous)
    }

    /// 五格缺一不可、型別要對(MIN-03 同款);`previous` 的本機帳目原樣帶過去;tokens 取 JSONL 的 `turn.completed.usage`。
    public static func parseOutput(lastMessage: String?, stdout: String, exitCode: Int32, stderr: String = "",
                                   previous: MinutesDocument? = nil, now: Date = Date()) throws -> MinutesDocument {
        if CodexCLIRunner.looksNotLoggedIn(exitCode: exitCode, stdout: stdout, stderr: stderr) { throw MinutesError.codexNotLoggedIn }
        if exitCode != 0 { throw MinutesError.failed(exitCode, "CLI 回報錯誤") }
        guard let so = CodexCLIRunner.finalJSONObject(lastMessage: lastMessage, stdout: stdout) else {
            throw MinutesError.badOutput("沒有 JSON 回應")
        }
        guard let summary = so["summary"] as? String else { throw MinutesError.badOutput("缺欄位 summary") }
        func list(_ key: String) throws -> [String] {
            guard let raw = so[key] as? [Any] else { throw MinutesError.badOutput("缺欄位 \(key)") }
            return try raw.map { item in
                guard let s = item as? String else { throw MinutesError.badOutput("欄位 \(key) 型別錯") }
                return s
            }
        }
        let u = CodexCLIRunner.usage(in: stdout)
        return MinutesDocument(summary: summary, decisions: try list("decisions"), actions: try list("actions"),
                               questions: try list("questions"), timeline: try list("timeline"),
                               updatedAt: now, inputTokens: u.input, outputTokens: u.output,
                               transcriptLinesConsumed: previous?.transcriptLinesConsumed ?? 0)
    }
}
