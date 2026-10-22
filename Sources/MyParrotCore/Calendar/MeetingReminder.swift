import Foundation

// #2407 行事曆觸發錄音(CAL)第一階段:純決策部分,SelfTest 直接驗。
// 讀行事曆(EventKit)、發通知、計時器都在 app target;這裡沒有任何副作用。

/// 一個可勾選的日曆(CAL-12 設定頁列的)。
public struct CalendarInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// 帳號/來源名稱(例如 Google、iCloud),設定頁分組用。
    public let source: String
    public init(id: String, title: String, source: String) {
        self.id = id; self.title = title; self.source = source
    }
}

/// 一個行事曆事件,只留篩選要用的欄位。時間一律是絕對時間(`Date`),時區只在顯示時才出現(CAL-02)。
public struct CalendarEventInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// 事件被取消,或自己已拒絕(CAL-01:都不提醒)。
    public let isCancelled: Bool
    public init(id: String, calendarID: String, title: String, start: Date, end: Date,
                isAllDay: Bool = false, isCancelled: Bool = false) {
        self.id = id; self.calendarID = calendarID; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay; self.isCancelled = isCancelled
    }
}

/// 設定(CAL-12)。預設**關**;關閉時 `select` 回空、排程器不建 store、不請求權限(CAL-03)。
public struct ReminderSettings: Sendable, Equatable {
    public var enabled = false
    public var calendarIDs: Set<String> = []
    public var keywords: [String] = ReminderSettings.defaultKeywords
    public var leadMinutes = 2
    /// CAL-07:使用者自填的一行 shell;空＝不跑。App 內不寫死任何服務(開源邊界)。
    public var externalCommand = ""
    public init() {}

    /// 預設關鍵字是通用詞,不帶任何業務詞(Eric 2026-10-17 14:55:MyParrot 要開源)。
    public static let defaultKeywords = ["會議", "面談", "面試", "諮詢", "meeting", "interview", "call"]

    /// 設定頁的一行文字 → 關鍵字清單:逗號(全半形)、分號、換行分隔;去空白、去空項、不分大小寫去重。
    public static func parseKeywords(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(whereSeparator: { ",，;；\n".contains($0) }) {
            let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            if seen.insert(k.lowercased()).inserted { out.append(k) }
        }
        return out
    }

    public static func joinKeywords(_ keywords: [String]) -> String { keywords.joined(separator: ", ") }
}

/// 一場要提醒的會議:去重鍵、事件、提醒時刻(開始 − 提前分鐘)。
public struct PlannedReminder: Sendable, Hashable {
    public let key: String
    public let event: CalendarEventInfo
    public let fireAt: Date
    public init(key: String, event: CalendarEventInfo, fireAt: Date) {
        self.key = key; self.event = event; self.fireAt = fireAt
    }
}

public enum MeetingReminderRules {
    /// CAL-05 去重鍵＝事件 id ＋ 開始時間(UTC ISO)。重複事件每個 occurrence 各一把鍵。
    public static func key(eventID: String, start: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return "\(eventID)@\(f.string(from: start))"
    }

    /// 標題不分大小寫含任一關鍵字。
    public static func matches(title: String, keywords: [String]) -> Bool {
        let t = title.lowercased()
        return keywords.contains { !$0.isEmpty && t.contains($0.lowercased()) }
    }

    /// CAL-01:篩出要提醒的場次。只認勾選的日曆;全天、已取消不算;只看**還沒開始**的
    /// (`start > now`);提醒時刻可能已過(例如睡醒才算到)——那也回傳,由排程器立刻發(CAL-04)。
    /// 同鍵只留一筆;依提醒時刻排序。
    public static func select(events: [CalendarEventInfo], settings: ReminderSettings,
                              now: Date, horizon: TimeInterval = 24 * 3600) -> [PlannedReminder] {
        guard settings.enabled else { return [] }
        let lead = TimeInterval(max(0, settings.leadMinutes) * 60)
        var seen = Set<String>()
        var out: [PlannedReminder] = []
        for e in events {
            guard settings.calendarIDs.contains(e.calendarID), !e.isAllDay, !e.isCancelled else { continue }
            guard e.start > now, e.start <= now.addingTimeInterval(horizon) else { continue }
            guard matches(title: e.title, keywords: settings.keywords) else { continue }
            let k = key(eventID: e.id, start: e.start)
            guard seen.insert(k).inserted else { continue }
            out.append(PlannedReminder(key: k, event: e, fireAt: e.start.addingTimeInterval(-lead)))
        }
        return out.sorted { $0.fireAt < $1.fireAt }
    }
}

/// CAL-03:行事曆來源抽象。v1 只有 EventKit(app target);將來 Google Calendar API 等
/// 都是另一個實作,規則層不變。
public protocol CalendarSource: AnyObject {
    func calendars() async throws -> [CalendarInfo]
    func events(from: Date, to: Date) async throws -> [CalendarEventInfo]
}
