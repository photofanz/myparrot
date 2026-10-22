import Foundation

/// CAL-02(F1＋雙時區,Eric 2026-10-17 11:59):事件是絕對時間,顯示才分時區。
/// 本機時區與台北同偏移 → 只顯示一個時間;不同 → 兩個並排,本機那邊**標時區名稱**
/// (「本機」兩個字在歐洲過一個夏令時就對不起來,所以寫 `Berlin (UTC+2)` 這種)。
/// 通知、設定頁、日誌三處都走這裡,格式只有一份。
public enum DualTimeZoneFormat {
    public static let taipei = TimeZone(identifier: "Asia/Taipei")!

    public struct Parts: Sendable, Equatable {
        /// 參考時區(台北)的時間,例「14:30」。
        public let reference: String
        /// 本機時區的時間,例「08:30」。
        public let local: String
        /// 本機時區名稱,例「Berlin (UTC+2)」。
        public let localZone: String
        /// 兩邊同一個偏移 → 只該顯示 `reference`。
        public let isSame: Bool
        public init(reference: String, local: String, localZone: String, isSame: Bool) {
            self.reference = reference; self.local = local; self.localZone = localZone; self.isSame = isSame
        }
    }

    public static func parts(_ date: Date, local: TimeZone, reference: TimeZone = taipei,
                             includeDate: Bool = false) -> Parts {
        let same = local.secondsFromGMT(for: date) == reference.secondsFromGMT(for: date)
        return Parts(reference: clock(date, reference, includeDate: includeDate),
                     local: clock(date, local, includeDate: includeDate),
                     localZone: zoneName(local, at: date), isSame: same)
    }

    /// 「Europe/Berlin」→「Berlin (UTC+2)」(夏令時)/「Berlin (UTC+1)」(冬令時)。
    /// 不用 `abbreviation(for:)`:它跟本機語系走,zh_TW 底下 Berlin 回「GMT+2」、en 才回 CEST,
    /// 不穩定;UTC 偏移語系無關,而且夏令時一樣看得出來。
    public static func zoneName(_ tz: TimeZone, at date: Date) -> String {
        let city = tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
        return "\(city) (\(utcOffset(tz, at: date)))"
    }

    /// 「UTC+8」「UTC-7」「UTC+5:30」。
    public static func utcOffset(_ tz: TimeZone, at date: Date) -> String {
        let secs = tz.secondsFromGMT(for: date)
        let sign = secs < 0 ? "-" : "+"
        let h = abs(secs) / 3600, m = (abs(secs) % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
    }

    /// 繁中預設呈現;App 層用 `Lf("%@ 台北 ／ %@ %@", …)` 換語言,模板一樣。
    public static func zhTW(_ p: Parts) -> String {
        p.isSame ? p.reference : "\(p.reference) 台北 ／ \(p.local) \(p.localZone)"
    }

    public static func clock(_ date: Date, _ tz: TimeZone, includeDate: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = includeDate ? "MM/dd HH:mm" : "HH:mm"
        return f.string(from: date)
    }
}
