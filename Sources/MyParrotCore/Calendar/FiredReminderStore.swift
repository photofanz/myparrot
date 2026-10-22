import Foundation

/// CAL-05 已發紀錄。檔在 `~/.config/myparrot/reminders-fired.json`(與 CLI 的 config 同目錄,
/// `MYPARROT_CONFIG_DIR` 可覆寫);格式刻意簡單(`{"version":1,"fired":{"<鍵>":"<ISO 時間>"}}`),
/// 因為 #2429 的 launchd 腳本要共用:**發前先查、發後即寫**,兩邊才不會重複發。
/// 原子寫;壞檔視為空(呼叫端記 log);超過保留期的鍵每次寫入時順手清掉。
public struct FiredReminderStore: Sendable {
    public struct Document: Codable, Equatable, Sendable {
        public var version = 1
        public var fired: [String: Date]
        public init(version: Int = 1, fired: [String: Date]) { self.version = version; self.fired = fired }
    }

    public let url: URL
    public var retention: TimeInterval = 7 * 86400

    public init(url: URL = FiredReminderStore.defaultURL) { self.url = url }

    /// 與 CLI `CLIConfigStore.configDir` 同一條規則(env 覆寫 → `~/.config/myparrot`)。
    /// #949 第一段:規則本體在 `MyParrotPaths.configDir`(Core/CLI/GUI 共用一份)。
    public static var configDir: URL { MyParrotPaths.configDir }
    public static var defaultURL: URL { configDir.appendingPathComponent("reminders-fired.json") }

    /// 純函式:丟掉超過保留期的鍵。
    public static func prune(_ fired: [String: Date], now: Date, retention: TimeInterval) -> [String: Date] {
        fired.filter { now.timeIntervalSince($0.value) <= retention }
    }

    /// 檔不存在 → 空;存在但解不開 → 空(`isCorrupt` 會回 true 讓呼叫端記 log)。
    public func load(now: Date = Date()) -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let doc = try? dec.decode(Document.self, from: data) else { return [:] }
        return Self.prune(doc.fired, now: now, retention: retention)
    }

    public var isCorrupt: Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Document.self, from: data)) == nil
    }

    public func contains(_ key: String, now: Date = Date()) -> Bool { load(now: now)[key] != nil }

    /// 讀 → 加鍵 → 清過期 → 原子寫回。回傳寫回後的內容。
    @discardableResult
    public func markFired(_ key: String, at now: Date = Date()) throws -> [String: Date] {
        var fired = load(now: now)
        fired[key] = now
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(Document(fired: fired))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return fired
    }
}
