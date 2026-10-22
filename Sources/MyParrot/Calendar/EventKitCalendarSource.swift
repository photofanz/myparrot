import Foundation
import EventKit
import MyParrotCore

/// CAL-03:v1 的行事曆來源＝macOS 行事曆(EventKit)。Google 日曆經「系統設定 → 網際網路帳號」
/// 同步進來就讀得到(Eric 2026-10-17 J1 確認已加入),零 OAuth、零 token,也沒有開源 repo
/// 放不了 client secret 的問題。`EKEventStore` **只在第一次需要時才建**,請求權限只在使用者
/// 打開總開關那一刻;預設關 ⇒ 零權限請求。
@MainActor
final class EventKitCalendarSource: CalendarSource {
    private var store: EKEventStore?

    var authorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var isAuthorized: Bool { authorization == .fullAccess }

    /// 已授權直接回 true;未決定才會跳系統詢問;被拒回 false(呼叫端顯示「未授權」＋開系統設定)。
    /// 最後一次請求的結果(除錯/狀態 JSON 用):系統回的錯誤字串、請求前後的原始狀態。
    private(set) var lastRequestError: String?
    private(set) var lastRequestStatusBefore: Int?
    var rawStatus: Int { authorization.rawValue }

    func requestAccess() async -> Bool {
        let s = ensureStore()
        lastRequestStatusBefore = authorization.rawValue
        if isAuthorized { return true }
        if authorization == .denied || authorization == .restricted {
            lastRequestError = "status \(authorization.rawValue) (denied/restricted) before request"
            return false
        }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            s.requestFullAccessToEvents { ok, err in cont.resume(returning: (ok, err.map { "\($0)" })) }
        }
        lastRequestError = err ?? (ok ? nil : "request returned false without error (status now \(authorization.rawValue))")
        return ok
    }

    private func ensureStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    func calendars() async throws -> [CalendarInfo] {
        guard isAuthorized else { throw CalendarSourceError.notAuthorized }
        return ensureStore().calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func events(from: Date, to: Date) async throws -> [CalendarEventInfo] {
        guard isAuthorized else { throw CalendarSourceError.notAuthorized }
        let s = ensureStore()
        let pred = s.predicateForEvents(withStart: from, end: to, calendars: nil)
        return s.events(matching: pred).map { e in
            let declined = e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            return CalendarEventInfo(id: e.eventIdentifier ?? e.calendarItemIdentifier,
                                     calendarID: e.calendar.calendarIdentifier,
                                     title: e.title ?? "",
                                     start: e.startDate, end: e.endDate,
                                     isAllDay: e.isAllDay,
                                     isCancelled: e.status == .canceled || declined)
        }
    }

    /// 行事曆有變動(新預約、改期、取消)→ 呼叫端重讀。store 還沒建(功能關著)就不掛。
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol? {
        guard let store else { return nil }
        return NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}

enum CalendarSourceError: Error, CustomStringConvertible {
    case notAuthorized
    var description: String { "calendar not authorized" }
}
