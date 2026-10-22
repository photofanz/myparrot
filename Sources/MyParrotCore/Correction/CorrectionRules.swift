import Foundation

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
