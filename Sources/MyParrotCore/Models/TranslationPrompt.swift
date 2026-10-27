import Foundation

/// #2612 TRL-05:翻譯的提示詞與輸出 schema。**沒有參數可以塞講者、時間、檔名、路徑、筆記**——使用者訊息只由
/// 「編號＋行文字」組成,簽章本身就是資料範圍的保證,SelfTest 與假 CLI 腳本再釘一次。兩家 CLI 後端共用同一份字串。
public enum TranslationPrompt {
    public static func system(to target: TranslationTarget) -> String {
        "You translate meeting transcript lines into \(target.promptName). Translate each numbered line faithfully. Keep the numbering order; do not merge, split or omit lines. Keep personal names, product names and code identifiers as they are. Do not add commentary. Reply with JSON only."
    }

    public static func user(lines: [String], to target: TranslationTarget) -> String {
        let head = "Translate the following \(lines.count) transcript lines to \(target.promptName). Return exactly \(lines.count) strings in the same order, one per line, without the numbers."
        let body = lines.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return head + "\n" + body
    }

    /// 結構化輸出:只有一個字串陣列。
    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["lines"],"properties":{"lines":{"type":"array","items":{"type":"string"}}}}
    """

    /// 兩家共用的解析:`lines` 要是字串陣列、長度＝送出行數(不符 ⇒ 整批作廢);模型若把「1: 」留著就剝掉。
    public static func parseLines(_ obj: [String: Any], expected: Int) throws -> [String] {
        guard let raw = obj["lines"] as? [Any] else { throw TranslationError.badOutput("缺欄位 lines") }
        let strings: [String] = try raw.map { item in
            guard let s = item as? String else { throw TranslationError.badOutput("欄位 lines 型別錯") }
            return s
        }
        guard strings.count == expected else { throw TranslationError.badOutput("行數不符(送 \(expected) 回 \(strings.count))") }
        return strings.enumerated().map { stripNumber($0.element, index: $0.offset + 1) }
    }

    /// 「12: 文字」「12. 文字」「12） 文字」開頭且編號＝該行序號 ⇒ 剝掉;其他原樣。
    static func stripNumber(_ s: String, index: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for sep in [": ", ":", ". ", "．", "）", ") "] {
            let prefix = "\(index)\(sep)"
            if trimmed.hasPrefix(prefix) { return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        return trimmed
    }
}
