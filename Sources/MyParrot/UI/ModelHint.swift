import Foundation
import MyParrotCore

/// UI-57 首次啟動模型功能提示(Eric 2026-10-20 12:45「1st run 也沒有提示 user?」⇒ 12:51 A1 一次性說明框)。
/// 偏好鍵 `modelHintShown`:沒設 ⇒ 主視窗出現後跳一次說明框(RootView),按「打開設定」或「稍後」都標 true 永不再跳;
/// 已經選過任一模型後端的人視同知道,直接標 true 不跳。🚫 不自動開任何功能,只是帶路。
enum ModelHint {
    static let key = "modelHintShown"

    static var shown: Bool { UserDefaults.standard.bool(forKey: key) }

    static func markShown() { UserDefaults.standard.set(true, forKey: key) }

    /// DEBUG `model-hint reset` 用:下次啟動再跳。
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// 該不該跳:沒跳過,且兩個能力都還是關的。
    static func shouldShow() -> Bool {
        if shown { return false }
        if ModelBackendRegistry.isEnabled(.correction) || ModelBackendRegistry.isEnabled(.minutes) {
            markShown()
            return false
        }
        return true
    }
}
