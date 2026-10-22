import AppKit
import UserNotifications
import MyParrotCore

/// CAL-06/08/11:macOS 通知。三種類別——會議提醒(帶「開始錄音」鈕)、沒人說話(帶「停止錄音」鈕)、
/// 純告知。文字只問「要開始錄音嗎?」加時間,不帶任何說明(Eric D1:MyParrot 要開源)。
/// ⚠️ `UNUserNotificationCenter` 只在 .app bundle 內能用,`swift run` 會直接崩;`available` 擋住。
/// 權限只在使用者打開會議提醒總開關那一刻請求(預設關 ⇒ 零請求)。
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    static let categoryReminder = "tw.uncle.MyParrot.meetingReminder"
    static let actionStart = "startRecording"
    static let categorySilence = "tw.uncle.MyParrot.silenceStop"
    static let actionStop = "stopRecording"
    static let categoryInfo = "tw.uncle.MyParrot.info"

    let available: Bool
    /// nil＝還沒查;true/false＝系統通知權限。
    private(set) var authorized: Bool?
    /// 系統回的原始狀態(UNAuthorizationStatus.rawValue:0 未決定/1 拒絕/2 允許/3 暫時);除錯用。
    private(set) var authorizationRaw: Int?
    private(set) var installed = false
    /// 這一輪送出去的通知(狀態 JSON/驗證用):id、類別、時間。
    private(set) var posted: [(id: String, category: String, at: Date)] = []
    /// 使用者按了哪個動作(驗證用)。
    private(set) var lastAction: (category: String, action: String, at: Date)?

    /// App 層接的動作:開錄(帶會議標題)、停錄。
    var onStartRecording: ((String) -> Void)?
    var onStopRecording: (() -> Void)?

    override init() {
        available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        super.init()
    }

    func install() {
        guard available, !installed else { return }
        installed = true
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let start = UNNotificationAction(identifier: Self.actionStart, title: L("開始錄音"), options: [.foreground])
        let stop = UNNotificationAction(identifier: Self.actionStop, title: L("停止錄音"), options: [])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryReminder, actions: [start], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.categorySilence, actions: [stop], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.categoryInfo, actions: [], intentIdentifiers: [], options: []),
        ])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            let raw = s.authorizationStatus.rawValue
            Task { @MainActor in self.authorized = ok; self.authorizationRaw = raw }
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard available else { return false }
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = ok
        refreshAuthorization()
        return ok
    }

    /// 除錯:問系統「目前還掛在通知中心的」通知 id(驗證橫幅有沒有真的送出去)。
    func deliveredIDs() async -> [String] {
        guard available else { return [] }
        let list = await UNUserNotificationCenter.current().deliveredNotifications()
        return list.map { $0.request.identifier }
    }

    func post(id: String, title: String, body: String, category: String, userInfo: [String: String] = [:]) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        content.userInfo = userInfo
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            Task { @MainActor in
                if err == nil { self.posted.append((id, category, Date())) }
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前景時也要跳橫幅(人正在 Meet 視窗前,App 可能在後面)。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        var info: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo {
            if let ks = k as? String, let vs = v as? String { info[ks] = vs }
        }
        await MainActor.run { self.handle(action: action, category: category, userInfo: info) }
    }

    /// 只有明確按「開始錄音」鈕才開錄;點通知本體只是把 App 帶到前面(避免誤觸開錄)。
    func handle(action: String, category: String, userInfo: [String: String]) {
        lastAction = (category, action, Date())
        switch (category, action) {
        case (Self.categoryReminder, Self.actionStart):
            onStartRecording?(userInfo["title"] ?? "")
        case (Self.categorySilence, Self.actionStop):
            onStopRecording?()
        case (_, UNNotificationDefaultActionIdentifier):
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
    }
}
