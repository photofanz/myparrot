import Foundation

/// 一場錄音的筆記 sidecar(#2438 L1:`<stem>.notes.md` 人寫;會議記錄另放 `<stem>.minutes.md`)。
///
/// 檔案格式(spec §4/§5):UTF-8 純文字 Markdown;第一行 `# <會議名稱>`;標記列 `⚑ h:mm:ss `;
/// 引用 `> <講者> h:mm:ss：<原文>`;不寫 frontmatter。任何 md 工具都讀得懂。
/// Core 不放 UI 字串:講者字、標題都由呼叫端傳入。
public struct NotesDocument: Sendable, Equatable {
    /// 錄音檔去副檔名的 URL(見 `SidecarSet`)。
    public let stem: URL

    public init(stem: URL) { self.stem = stem }
    /// 從錄音檔 URL(`.caf`/`.m4a`)建。
    public init(recordingURL: URL) { self.stem = SidecarSet.stem(of: recordingURL) }

    public static let fileExtension = "notes.md"
    /// 待錄音草稿的檔名(點開頭＝Finder 隱藏;開錄時改名成該場的 notes)。
    public static let draftFileName = ".draft.notes.md"

    /// `<stem>.notes.md`
    public var url: URL { SidecarSet.url(stem: stem, ext: Self.fileExtension) }

    /// `<dir>/.draft.notes.md`
    public static func draftURL(in dir: URL) -> URL { dir.appendingPathComponent(draftFileName) }

    /// 新筆記的預設內容:第一行 `# <會議名稱>`。
    public static func initialText(title: String) -> String { "# \(title)\n" }

    /// 時間碼 `hh:mm:ss`(小時至少兩位;負數/非有限值當 0;秒數無條件捨去)。
    public static func timecode(_ elapsed: TimeInterval) -> String {
        let total = elapsed.isFinite && elapsed > 0 ? Int(elapsed.rounded(.down)) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 標記 `⚑ 00:12:34 `(尾端一個空白,游標接著打字)。
    public static func marker(at elapsed: TimeInterval) -> String { "⚑ \(timecode(elapsed)) " }

    /// 引用到筆記:`> <講者> 00:13:02：<原文>\n`;原文多行 ⇒ 每行都帶 `> `(仍在同一個引用區塊)。
    /// - separator:講者時間與原文之間的分隔,預設全形「：」照 spec §4 檔案格式;App 層可依語言傳 `": "`。
    /// 原文前後空白與尾端換行去掉;`\r\n` 視同 `\n`。
    public static func quote(speakerLabel: String, elapsed: TimeInterval, text: String,
                             separator: String = "：") -> String {
        let body = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.components(separatedBy: "\n")
        var out = "> \(speakerLabel) \(timecode(elapsed))\(separator)\(lines[0])\n"
        for line in lines.dropFirst() { out += line.isEmpty ? ">\n" : "> \(line)\n" }
        return out
    }
}
