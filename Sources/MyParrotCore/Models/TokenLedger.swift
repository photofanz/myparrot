import Foundation

/// #2623 TOK-01(Eric 2026-10-27「先做每一場會議的統計」):**一場一本帳** `<stem>.tokens.json`。
/// 校正／會議記錄／翻譯每次**成功**呼叫追加一筆(失敗拿不到 usage,不記);畫面(檔案面板右鍵、逐字稿欄底一行)
/// 與 DebugControl 都讀同一份。改名／垃圾桶跟著錄音走(`SidecarSet.extensions` 有 `tokens.json`);
/// 跨天總帳(#2623 第二步)掃資料夾加總即可。
public struct TokenEntry: Codable, Sendable, Equatable {
    public var at: Date
    /// `ModelCapability.rawValue`:correction／minutes／translation。
    public var feature: String
    /// 後端 id(off／claudeCLI／codexCLI／appleFM／appleTranslation／localFake)。
    public var backend: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int
    /// 這一筆處理了幾段／幾行。
    public var units: Int
    /// Apple 本機模型不回 usage,數字是估算 ⇒ 畫面前加 ≈。
    public var estimated: Bool

    public init(at: Date = Date(), feature: ModelCapability, backend: String, inputTokens: Int, outputTokens: Int,
                durationMs: Int, units: Int, estimated: Bool = false) {
        self.at = at; self.feature = feature.rawValue; self.backend = backend
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.durationMs = durationMs
        self.units = units; self.estimated = estimated
    }
}

/// 加總(一個能力、一個後端、或全場)。
public struct TokenSum: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var calls = 0
    public var durationMs = 0
    public var units = 0
    /// 任一筆是估算 ⇒ 整個加總標 ≈。
    public var estimated = false
    public var total: Int { inputTokens + outputTokens }
    public init() {}

    mutating func add(_ e: TokenEntry) {
        inputTokens += e.inputTokens; outputTokens += e.outputTokens; calls += 1
        durationMs += e.durationMs; units += e.units; estimated = estimated || e.estimated
    }
}

public struct TokenTotals: Sendable, Equatable {
    public var byFeature: [String: TokenSum] = [:]
    public var byFeatureBackend: [String: [String: TokenSum]] = [:]
    public var all = TokenSum()
    public init() {}
}

public enum TokenLedger {
    public static let ext = "tokens.json"
    /// 追加成功後在 main 發(userInfo `stem`＝URL);App 層的 NotesSession 聽到就重讀。
    public static let didChange = Notification.Name("tw.uncle.MyParrot.tokenLedgerDidChange")
    public static let stemKey = "stem"

    struct File: Codable {
        var version: Int
        var entries: [TokenEntry]
    }

    public static func url(stem: URL) -> URL { SidecarSet.url(stem: stem, ext: ext) }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// 壞檔／缺檔 ⇒ 空帳,不丟錯。
    public static func load(stem: URL) -> [TokenEntry] {
        guard let data = try? Data(contentsOf: url(stem: stem)),
              let f = try? decoder.decode(File.self, from: data) else { return [] }
        return f.entries
    }

    /// 讀—加—原子寫;寫失敗只回 false(呼叫端記 log,不影響功能)。
    @discardableResult
    public static func append(stem: URL, _ entry: TokenEntry) -> Bool {
        var entries = load(stem: stem)
        entries.append(entry)
        guard let data = try? encoder.encode(File(version: 1, entries: entries)) else { return false }
        do { try data.write(to: url(stem: stem), options: .atomic) } catch { return false }
        let u = stem
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: [stemKey: u])
        }
        return true
    }

    public static func totals(_ entries: [TokenEntry]) -> TokenTotals {
        var t = TokenTotals()
        for e in entries {
            t.all.add(e)
            t.byFeature[e.feature, default: TokenSum()].add(e)
            t.byFeatureBackend[e.feature, default: [:]][e.backend, default: TokenSum()].add(e)
        }
        return t
    }

    /// 1234 → "1.2k"、999 → "999"、1_250_000 → "1.3M"。
    public static func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
