import Foundation

/// UI-59(BUG-38):校正建議清單的高度政策——清單自己捲,高度＝min(內容高度, 上限);量到之前(0)給 1pt 讓內容先排版。
public enum CorrectionListLayout {
    public static let maxHeight: Double = 360
    public static func height(content: Double, cap: Double = maxHeight) -> Double { min(max(content, 1), cap) }
}

/// UI-60:建議列 → 逐字稿對應段的純決策(點列跳段、列內展開原句、要不要先切「完整」)。
public enum CorrectionFocus {
    /// 段號對到 `liveTranscript` 的索引;稿已重轉變短、段號越界 ⇒ nil(不跳、不崩)。
    public static func lineIndex(segment: Int, count: Int) -> Int? {
        (0..<count).contains(segment) ? segment : nil
    }
    /// 原句裡 `original` 第一個逐字連續命中的範圍(前後空白先 trim;空字串／沒命中 ⇒ nil)。
    public static func highlightRange(original: String, in text: String) -> Range<String.Index>? {
        let needle = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return text.range(of: needle)
    }
    /// 該行不在目前可見視窗(3 分鐘)裡 ⇒ 要先切「完整」才捲得到。
    public static func needsFullTranscript(lineID: UUID, visible: [TranscriptLine]) -> Bool {
        !visible.contains { $0.id == lineID }
    }
}

/// 逐字稿校正層(#2417)——一則「建議」:把第 `segment` 段裡的 `original` 改成
/// `suggestion`。形狀照拾音(Shiyin):LLM 只能指出位置與替換字串,不能重寫整段;
/// `original` 必須在該段原文裡**一字不差、連續出現**,否則整則作廢(見 `CorrectionRules.validate`)。
public struct CorrectionSuggestion: Codable, Hashable, Sendable {
    public var segment: Int
    public var original: String
    public var suggestion: String
    public var reason: String

    public init(segment: Int, original: String, suggestion: String, reason: String) {
        self.segment = segment; self.original = original; self.suggestion = suggestion; self.reason = reason
    }

    /// 同段同 original 視為同一則(去重用)。
    public var dedupeKey: String { "\(segment)\u{1F}\(original)" }
}

/// 校正層的純決策(CORR-03/04):無副作用、不碰檔案、不碰 UI,SelfTest 直接驗。
public enum CorrectionRules {
    /// 丟掉不能用的建議(照 Shiyin `validate()`):段號不在這一批、`original` 空白、
    /// 改了等於沒改、`original` 在該段原文裡找不到、同段同 `original` 重複。
    /// `original`/`suggestion` 前後空白先 trim 再比對;比對是**逐字連續**(`contains`)。
    public static func validate(_ raw: [CorrectionSuggestion],
                                segments: [String],
                                range: Range<Int>) -> [CorrectionSuggestion] {
        var seen = Set<String>()
        return raw.compactMap { r in
            var s = r
            s.original = s.original.trimmingCharacters(in: .whitespacesAndNewlines)
            s.suggestion = s.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard range.contains(s.segment), s.segment < segments.count,
                  !s.original.isEmpty, s.original != s.suggestion,
                  segments[s.segment].contains(s.original),
                  seen.insert(s.dedupeKey).inserted else { return nil }
            return s
        }
    }

    /// 套用一則:把該段裡**第一個** `original` 換成 `suggestion`。段落在建議產生後
    /// 已被人改過、找不到 `original` ⇒ 回 nil、什麼都不動。
    public static func apply(_ s: CorrectionSuggestion, to text: String) -> String? {
        guard let r = text.range(of: s.original) else { return nil }
        return text.replacingCharacters(in: r, with: s.suggestion)
    }

    /// 還原:把第一個 `suggestion` 換回 `original`。找不到 ⇒ nil。
    public static func revert(_ s: CorrectionSuggestion, in text: String) -> String? {
        guard let r = text.range(of: s.suggestion) else { return nil }
        return text.replacingCharacters(in: r, with: s.original)
    }

    /// 分批:`count` 段切成每批最多 `size` 段的連續區間(CORR-06 的批次上限)。
    public static func batches(count: Int, size: Int) -> [Range<Int>] {
        guard count > 0, size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }
}
