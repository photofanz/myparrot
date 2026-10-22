import Foundation

/// CAL-09(I1,Eric 2026-10-17 15:08):「沒人說話」的量尺,跟既有的「死軌」門檻是兩把尺。
/// 由來:真錄音實測麥軌底噪 -54~-59 dBFS,高於死軌門檻 0.003(含 4 倍 UI 增益=真 -62.5 dBFS),
/// 所以活的麥光靠房間底噪就算「有訊號」;C2 的「30 分鐘沒人說話」要另一把會跟裝置走的尺。
/// 做法:滾動視窗內的最低 RMS 當底噪(單調 deque,O(1) 攤提),超過底噪 × 4(+12 dB)才算有人說話。
/// 視窗取 5 分鐘(不是 60 秒):連續講一分鐘不喘氣時 60 秒最小值會被講話本身頂高,把後面的話判成安靜;
/// 5 分鐘內一定有句間停頓,底噪估得穩。餵進來的 level 就是 `onLevel` 的值(含 4 倍增益),不用換算。
public struct SpeechActivityEstimator: Sendable {
    public var windowSeconds: TimeInterval
    /// 底噪乘這個倍數才算說話;4 ＝ +12 dB。
    public var marginFactor: Float
    /// 底噪下限:全零軌(數位靜音)的底噪是 0,乘幾倍都是 0,沒有下限會把任何雜訊當說話。
    public var floorMin: Float
    /// 數位靜音門檻:低於它的 buffer(tap 全零、閘控麥關閘、重建瞬間的零 buffer)**不參與底噪估計**,
    /// 否則一個零 buffer 就把底噪拉到下限、接下來 5 分鐘房間底噪全被當成說話(CAL-10 真錄音第 1 檔實測:
    /// 右軌 77% 的 buffer 被判成說話)。數位靜音本身永遠不算說話(0 < 任何門檻)。
    public var digitalSilence: Float = 1e-5

    private var window: [(t: TimeInterval, v: Float)] = []   // 值遞增的 deque,首項＝視窗最小值
    public private(set) var noiseFloor: Float
    public private(set) var lastLevel: Float = 0
    public private(set) var samples = 0

    public init(windowSeconds: TimeInterval = 300, marginFactor: Float = 4, floorMin: Float = 0.0005) {
        self.windowSeconds = windowSeconds
        self.marginFactor = marginFactor
        self.floorMin = floorMin
        self.noiseFloor = floorMin
    }

    public var speechThreshold: Float { max(noiseFloor, floorMin) * marginFactor }

    /// 餵一筆 level;`t` ＝ 錄音經過秒數(暫停不算)。回傳這一筆算不算「有人說話」。
    /// 判斷用的是**餵進來之前**的底噪:講話那一筆不該立刻把自己的門檻拉高。
    @discardableResult
    public mutating func observe(level v: Float, at t: TimeInterval) -> Bool {
        lastLevel = v
        samples += 1
        let isSpeech = v > speechThreshold
        if v > digitalSilence {
            while let last = window.last, last.v >= v { window.removeLast() }
            window.append((t, v))
        }
        while let first = window.first, t - first.t > windowSeconds { window.removeFirst() }
        noiseFloor = max(window.first?.v ?? floorMin, floorMin)
        return isSpeech
    }

    public mutating func reset() {
        window.removeAll()
        noiseFloor = floorMin
        lastLevel = 0
        samples = 0
    }
}

/// CAL-11(C2 改 30 分,Eric 2026-10-17 14:25):兩軌連續沒人說話 `after` 秒 → 建議停,**只發一次**;
/// 任一軌又有人說話就重新武裝。`t` 用錄音經過秒數,所以暫停中不計。第一階段只提醒,不自動停。
public struct SilenceStopRule: Sendable {
    public var after: TimeInterval
    public private(set) var lastSpeechAt: TimeInterval = 0
    public private(set) var armed = true

    public init(after: TimeInterval = 30 * 60) { self.after = after }

    /// 回傳 true ＝ 這一刻該建議停。
    @discardableResult
    public mutating func observe(anySpeech: Bool, at t: TimeInterval) -> Bool {
        if anySpeech {
            lastSpeechAt = t
            armed = true
            return false
        }
        guard armed, t - lastSpeechAt >= after else { return false }
        armed = false
        return true
    }

    public var silentFor: (TimeInterval) -> TimeInterval { { t in max(0, t - lastSpeechAt) } }

    public mutating func reset() { lastSpeechAt = 0; armed = true }
}

/// CAL-08(G1 改 3 分,Eric 2026-10-17 14:59):起錄後 `after` 秒內某軌**從頭到尾**沒有過真訊號
/// (死軌門檻,現行 0.003)→ 告警一次。「有沒有過訊號」用該軌開錄以來的最大值,正好就是從頭到尾。
public enum DeadTrackRule {
    public static func shouldAlarm(elapsed: TimeInterval, everHadSignal: Bool,
                                  alreadyAlarmed: Bool, after: TimeInterval = 180) -> Bool {
        !alreadyAlarmed && !everHadSignal && elapsed >= after
    }
}

/// 哪一軌(通知文字與狀態 JSON 用)。
public enum RecordingTrack: String, Sendable, Codable {
    case mic      // 你(右軌)
    case system   // 對方(左軌)
}
