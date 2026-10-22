import SwiftUI
import AppKit

/// 外觀設定(Eric 2026-10-20 12:40:「一般 app 的標準 SOP:可以設置 深色／淺色／隨系統,而不是做死」;UI-56)。
/// 偏好鍵 `appearanceMode`(`system`／`light`／`dark`),預設跟隨系統;改了立刻套到 `NSApp.appearance`
/// (所有視窗含設定頁、迷你藥丸一起變,不用重開),啟動時在第一個視窗建立前套回。
/// 🚫 不碰 macOS 系統外觀設定。DEBUG 的 `myparrotctl appearance light|dark|system` 仍是暫時覆寫(不寫偏好),
/// `appearance set <mode>` 才走這裡(與設定頁同一條路)。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    static let key = "appearanceMode"

    /// 設定頁顯示用的字串 key(走 `L()`)。
    var labelKey: String {
        switch self {
        case .system: return "跟隨系統"
        case .light: return "淺色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 偏好裡存的值;沒存過或存了怪值 ⇒ 跟隨系統。
    static var stored: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// 寫偏好並立刻套用(設定頁 picker 與 DebugControl `appearance set` 共用)。
    @MainActor static func select(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        apply(mode)
    }

    @MainActor static func apply(_ mode: AppearanceMode) {
        NSApp.appearance = mode.nsAppearance
    }

    /// 啟動時套回偏好(AppDelegate `applicationWillFinishLaunching`)。
    @MainActor static func applyStored() { apply(stored) }
}
