import Foundation
import CoreAudio

/// AUD-38(#2529):`MicCapture` 收到 `AVAudioEngineConfigurationChange` 之後「要不要拆、要不要鎖」的**純決策**。
/// 抽出來讓 SelfTest 不必起真引擎就能驗;所有輸入都是值,無副作用。
enum MicRebuildPolicy {
    /// 一次因裝置變更觸發的重建紀錄:何時、當時讀到的輸入格式鍵(例 "24000/1")。
    typealias Rebuild = (at: Date, key: String)

    /// 震盪鎖的觀察窗(秒)。
    static let window: TimeInterval = 20
    /// 觀察窗內同一格式鍵已重建過幾次,再來一次就鎖。
    static let maxRebuildsInWindow = 2

    /// 偽通知:引擎仍在跑、而且現在讀到的格式鍵＝tap 裝上時的格式鍵 ⇒ 什麼都沒變,不拆。
    /// 真機(#2529 探針四輪)start 後 60 ms 出現 3 次這種通知,引擎沒停、格式沒變、buffer 照流。
    static func isSpurious(engineRunning: Bool, currentKey: String, tapKey: String) -> Bool {
        engineRunning && currentKey == tapKey
    }

    /// 震盪鎖(放寬版):只對藍牙裝置;`window` 秒內同一格式鍵已經重建過 `maxRebuildsInWindow` 次,
    /// 這一次(第 3 次)就鎖住、不再自動重建。
    static func shouldLock(history: [Rebuild], now: Date, key: String, isBluetooth: Bool) -> Bool {
        guard isBluetooth else { return false }
        let recentSameKey = history.filter { $0.key == key && now.timeIntervalSince($0.at) <= window }
        return recentSameKey.count >= maxRebuildsInWindow
    }

    /// AUD-38 F2:只有讀得到、取樣率與聲道數都 >0 的格式鍵才記進震盪鎖紀錄(""、"0/0"、"48000/0" 不記;
    /// 端點還沒就緒時讀到的格式不代表 HFP 在反覆切換)。
    static func isRecordable(key: String) -> Bool {
        let parts = key.split(separator: "/")
        guard parts.count == 2, let rate = Int(parts[0]), let ch = Int(parts[1]) else { return false }
        return rate > 0 && ch > 0
    }

    /// 丟掉觀察窗以外(超過 `window` 秒)的紀錄。
    static func prune(_ history: [Rebuild], now: Date) -> [Rebuild] {
        history.filter { now.timeIntervalSince($0.at) <= window }
    }
}

/// AUD-38(#2529):你軌(麥克風)看門狗的**純決策**。輸入都是「距某事件多久」的秒數與計數,
/// 與 @MainActor 狀態無關;常數與 `RecordingController` AUD-28 看門狗原本的值一致。
enum MicWatchdogPolicy {
    /// 多久沒有 buffer 就算引擎死了(秒)。
    static let deadAfter: TimeInterval = 3
    /// 兩次自動重建之間的最短間隔(秒)。
    static let cooldown: TimeInterval = 2
    /// 連續自動重建上限;到了就不再重建(交給 8 秒無聲警告)。
    static let maxConsecutiveRebuilds = 3
    /// buffer 連續流動多久才把連續重建計數歸零(秒)。
    static let flowResetAfter: TimeInterval = 10
    /// AUD-38 F4:切麥／重建／開錄的 start 最多等多久(秒);藍牙最壞約保持器 3 秒＋建引擎 6 秒。
    static let switchTimeout: TimeInterval = 20

    /// 切換是否已逾時(開始後滿 `switchTimeout` 秒)。
    static func switchTimedOut(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= switchTimeout
    }

    /// 計數只在 buffer 連續流動 ≥ `flowResetAfter` 秒才歸零(不再每個 buffer 就歸零,
    /// 否則「建起來流 1 秒又死」的震盪永遠碰不到上限)。
    static func shouldResetCount(flowSince: Date?, now: Date) -> Bool {
        guard let flowSince else { return false }
        return now.timeIntervalSince(flowSince) >= flowResetAfter
    }

    /// 該不該自動重建:切換中不計時、被震盪鎖住不重建;其餘照 AUD-28(無 buffer 超過門檻、
    /// 連續次數未達上限、冷卻已過)。
    static func shouldRebuild(sinceLastBuffer: TimeInterval, count: Int, sinceLastRebuild: TimeInterval,
                              switching: Bool, locked: Bool) -> Bool {
        guard !switching, !locked else { return false }
        return sinceLastBuffer > deadAfter
            && count < maxConsecutiveRebuilds
            && sinceLastRebuild > cooldown
    }
}

/// AUD-39(#2529／BUG-35):建引擎前「系統預設輸入是否已穩定」的**純決策**。
/// 真機 R3:AirPods 消失瞬間系統預設輸入仍指著它,新引擎的 `inputNode` 建 AUHAL 會先開預設輸入,
/// 等到 HAL 放棄要 20.5 秒;所以碰 `inputNode` 之前先等預設輸入換到一顆還在的裝置。
enum MicDevicePolicy {
    /// 輪詢上限(秒);超時照建。
    static let settleTimeout: TimeInterval = 2.0
    static let pollInterval: TimeInterval = 0.1

    /// 預設輸入已穩定:有值、在系統裝置清單裡、而且不是剛被移除的那顆。
    static func defaultInputSettled(defaultID: AudioDeviceID, deviceIDs: [AudioDeviceID], removedID: AudioDeviceID?) -> Bool {
        defaultID != 0 && deviceIDs.contains(defaultID) && defaultID != removedID
    }
}
