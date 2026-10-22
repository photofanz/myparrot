import Foundation

/// #2438 Phase 2 滾動摘要的本機決策(純函式,MIN-04／05／09):哪些輪次不用花錢、失敗幾次自動暫停、
/// 重新附著一場時從哪一行接續。狀態本體在 App 層的 `MinutesController`。
public enum MinutesRolling {

    /// MIN-05:自動模式連續失敗這麼多次 ⇒ 暫停自動更新(手動成功一次就恢復)。
    public static let autoPauseThreshold = 3

    public struct Plan: Equatable, Sendable {
        /// 逐字稿比記錄裡「已吃到的行數」還少(重轉過)⇒ 從頭,previous 不帶。
        public var startOver: Bool
        /// 這次增量從第幾行開始。
        public var from: Int
    }

    /// MIN-09:重新附著同一場時從上次吃到的行數接續;行數對不上就從頭。
    public static func plan(transcriptCount: Int, consumed: Int) -> Plan {
        consumed > transcriptCount ? Plan(startOver: true, from: 0) : Plan(startOver: false, from: consumed)
    }

    /// MIN-04:自動輪次沒新定稿行、筆記也沒變(或筆記是空的)⇒ 不呼叫後端。手動一律呼叫。
    public static func shouldSkip(manual: Bool, deltaEmpty: Bool, notesChanged: Bool, notesEmpty: Bool) -> Bool {
        if manual || !deltaEmpty { return false }
        return !notesChanged || notesEmpty
    }

    /// MIN-04:筆記「實際上是空的」＝去掉第一行 `# 標題`(開錄時自動寫的會議名稱)後沒有內容。只有標題不算人標的重點,
    /// 不值得為它花一次呼叫。
    public static func notesIsEffectivelyEmpty(_ notes: String) -> Bool {
        var lines = notes.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("# ") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// MIN-05:要不要因為連續失敗而暫停自動更新。
    public static func shouldPauseAuto(consecutiveFailures: Int, manual: Bool) -> Bool {
        !manual && consecutiveFailures >= autoPauseThreshold
    }
}
