import Foundation

/// #2483 E(Eric 2026-10-20 15:31 A1):結束後高精度重轉的時機。偏好鍵 `autoTranscribePolicy`;
/// 舊布林 `autoTranscribe` 只在遷移時讀(true→whenIdle、false→never、沒設→whenIdle)。
public enum TranscribePolicy: String, CaseIterable, Sendable {
    case immediately, whenIdle, never

    public static let key = "autoTranscribePolicy"
    public static let legacyKey = "autoTranscribe"

    /// 純函式:新鍵有效值優先;沒有就看舊布林;都沒有 ⇒ 預設 whenIdle。
    public static func migrate(raw: String?, legacy: Bool?) -> TranscribePolicy {
        if let raw, let p = TranscribePolicy(rawValue: raw) { return p }
        if let legacy { return legacy ? .whenIdle : .never }
        return .whenIdle
    }
}

/// #2483 E(TRX-06):閒置時才重轉的判定,純函式。
public enum IdleTranscribePolicy {
    public static let idleThreshold: TimeInterval = 120
    public static let checkInterval: TimeInterval = 30

    public static func shouldRun(state: RecordingState, isTranscribing: Bool, onAC: Bool,
                                 idleSeconds: TimeInterval, pendingCount: Int) -> Bool {
        guard pendingCount > 0 else { return false }
        if state == .recording || state == .paused { return false }
        if isTranscribing { return false }
        if !onAC { return false }
        return idleSeconds >= idleThreshold
    }
}
