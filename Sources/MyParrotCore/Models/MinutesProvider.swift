import Foundation

/// #2438 G1/F3 會議記錄(MIN):滾動摘要的輸入——上一版結構化記錄＋自上次之後的逐字稿增量＋使用者筆記全文
/// (人標的重點,優先級最高)。資料範圍以 TEST_PLAN O 節為準;Core 不含任何供應商端點。
public struct MinutesInput: Sendable {
    public var previous: MinutesDocument?
    public var transcriptDelta: [String]
    public var notes: String
    public var language: TranscriptionLanguage

    public init(previous: MinutesDocument? = nil, transcriptDelta: [String] = [], notes: String = "",
                language: TranscriptionLanguage = .system) {
        self.previous = previous
        self.transcriptDelta = transcriptDelta
        self.notes = notes
        self.language = language
    }
}

/// 結構化會議記錄(`<stem>.minutes.json` 的內容;`MinutesMarkdown.render` 轉成 `<stem>.minutes.md`)。
/// 唯讀 AI 草稿:人要改就貼到筆記改,自動更新不覆蓋任何人寫的檔。
public struct MinutesDocument: Sendable, Codable, Equatable {
    public var summary: String
    public var decisions: [String]
    public var actions: [String]
    public var questions: [String]
    public var timeline: [String]
    public var updatedAt: Date
    public var inputTokens: Int
    public var outputTokens: Int
    /// Phase 2(MIN-09):這版記錄已經吃到逐字稿的第幾行(本機帳目,不送後端)。重新附著同一場時從這裡接續;
    /// 舊 JSON 沒這欄 ⇒ 0(從頭)。
    public var transcriptLinesConsumed: Int

    public init(summary: String = "", decisions: [String] = [], actions: [String] = [], questions: [String] = [],
                timeline: [String] = [], updatedAt: Date = Date(), inputTokens: Int = 0, outputTokens: Int = 0,
                transcriptLinesConsumed: Int = 0) {
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
        self.questions = questions
        self.timeline = timeline
        self.updatedAt = updatedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.transcriptLinesConsumed = transcriptLinesConsumed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        decisions = try c.decode([String].self, forKey: .decisions)
        actions = try c.decode([String].self, forKey: .actions)
        questions = try c.decode([String].self, forKey: .questions)
        timeline = try c.decode([String].self, forKey: .timeline)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        transcriptLinesConsumed = try c.decodeIfPresent(Int.self, forKey: .transcriptLinesConsumed) ?? 0
    }
}

/// 會議記錄後端介面(與 `CorrectionProvider` 同形)。Claude CLI、Apple 本機模型、將來本地小模型都實作它。
public protocol MinutesProvider: Sendable {
    func update(_ input: MinutesInput) async throws -> MinutesDocument
}

#if DEBUG
/// 假供應商(DEBUG 限定,MIN-00 shell 驗證用):不碰網路、不 spawn,回固定內容;時間軸每呼叫一次多一筆,
/// 讓「自動更新每 N 分」看得出跑了幾次。時鐘可注入。
public struct LocalFakeMinutesProvider: MinutesProvider {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func update(_ input: MinutesInput) async throws -> MinutesDocument {
        let n = (input.previous?.timeline.count ?? 0) + 1
        let newLines = input.transcriptDelta.count
        var timeline = input.previous?.timeline ?? []
        timeline.append("Update \(n): \(newLines) new line(s)")
        let inputChars = input.transcriptDelta.reduce(0) { $0 + $1.count } + input.notes.count
        return MinutesDocument(
            summary: "Fake minutes (DEBUG) - update \(n), \(newLines) new transcript line(s), notes \(input.notes.count) char(s).",
            decisions: ["Fake decision A", "Fake decision B"],
            actions: ["Fake action item"],
            questions: ["Fake open question?"],
            timeline: timeline,
            updatedAt: now(),
            inputTokens: inputChars,
            outputTokens: 120)
    }
}
#endif

/// 會議記錄 Markdown 的段落標題。Core 不放 UI 文字:App 層傳 `L(...)` 的結果進來,預設英文。
public struct MinutesLabels: Sendable, Equatable {
    public var summary: String
    public var decisions: String
    public var actions: String
    public var questions: String
    public var timeline: String
    /// 某段沒內容時放的佔位。
    public var empty: String

    public init(summary: String = "Summary", decisions: String = "Decisions", actions: String = "Action items",
                questions: String = "Open questions", timeline: String = "Timeline", empty: String = "—") {
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
        self.questions = questions
        self.timeline = timeline
        self.empty = empty
    }

    public static let english = MinutesLabels()
}

/// spec §6:四段(摘要／決議／待辦／待釐清)＋時間軸 → Markdown。五段永遠都在(結構固定,Phase 2 只換供應商);
/// 清單項目內的換行壓成空白、空白項略過;結尾恰一個換行。
public enum MinutesMarkdown {
    public static func render(_ d: MinutesDocument, labels: MinutesLabels = .english) -> String {
        var sections: [String] = []
        let summary = d.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("## \(labels.summary)\n\n\(summary.isEmpty ? labels.empty : summary)")
        let lists: [(String, [String])] = [
            (labels.decisions, d.decisions), (labels.actions, d.actions),
            (labels.questions, d.questions), (labels.timeline, d.timeline)
        ]
        for (title, items) in lists {
            let lines = items.map(flatten).filter { !$0.isEmpty }.map { "- \($0)" }
            sections.append("## \(title)\n\n\(lines.isEmpty ? labels.empty : lines.joined(separator: "\n"))")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// 一個清單項目壓成一行(換行 → 空白,去頭尾空白)。
    static func flatten(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
