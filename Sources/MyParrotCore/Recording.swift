import Foundation

/// A finished recording on disk.
public struct Recording: Identifiable, Hashable {
    public let id: UUID
    public var title: String          // e.g. "客戶會議-ABC公司"
    public var url: URL
    public var date: Date
    public var duration: TimeInterval
    public var hasTranscript: Bool
    public var isConverting: Bool

    public init(id: UUID, title: String, url: URL, date: Date,
                duration: TimeInterval, hasTranscript: Bool,
                isConverting: Bool = false) {
        self.id = id; self.title = title; self.url = url; self.date = date
        self.duration = duration; self.hasTranscript = hasTranscript
        self.isConverting = isConverting
    }

    /// 同名逐字稿 sidecar(`.txt`);`hasTranscript` 即此檔存在。
    public var transcriptURL: URL { url.deletingPathExtension().appendingPathExtension("txt") }

    /// Display filename per the PRD template: 日期+時間+會議名稱
    public static func fileName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: date)
        let safe = sanitizeTitle(title)
        return "\(stamp) \(safe).caf"
    }

    /// 標題進檔名前去掉路徑語意(v0.3.0 二審:`/`、`..` 會把單一檔名變成路徑成分——
    /// 「會議/客戶」會因中間目錄不存在而錄不起來)。`/` `:` → `-`,NUL/控制字元去掉,
    /// 前後空白與點去掉,上限 120 bytes UTF-8 邊界截斷;清完是空的 → 「錄音」。
    public static func sanitizeTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = String(String.UnicodeScalarView(t.unicodeScalars.filter { $0.properties.generalCategory != .control }))
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while t.utf8.count > 120 { t.removeLast() }
        return t.isEmpty ? "錄音" : t
    }

    /// 錄音/逐字稿會長出的副檔名——探測檔名衝突時全部算(#892)。
    public static let derivedExtensions = ["caf", "m4a", "txt", "srt", "json"]

    /// #892:同一分鐘同標題兩次錄音會算出同檔名 → 第二次靜默覆蓋第一次。
    /// 在 `dir` 內探測同 stem 的任一衍生檔存在就加 Finder 式後綴「 2」「 3」…;
    /// 無衝突時與 `fileName` 完全相同(REC-01 範本不變)。只防同機單進程;跨進程
    /// 同秒競爭交給並存協定(RENAME_EXCL)。
    public static func uniqueFileName(date: Date, title: String, in dir: URL,
                                      fm: FileManager = .default) -> String {
        let base = fileName(date: date, title: title)
        let stem = String(base.dropLast(4))   // 去掉 ".caf"
        func taken(_ s: String) -> Bool {
            derivedExtensions.contains { fm.fileExists(atPath: dir.appendingPathComponent("\(s).\($0)").path) }
        }
        guard taken(stem) else { return base }
        var n = 2
        while taken("\(stem) \(n)") { n += 1 }   // 二審:原本 n==1000 就回傳已佔用的名字
        return "\(stem) \(n).caf"
    }
}

/// One line of transcript. `isYou` decides bubble side (right) vs 對方 (left).
public struct TranscriptLine: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var isYou: Bool
    public var time: Date
    public var text: String
    public var isFinal: Bool
    /// Offset from the recording start, in seconds (for SRT timecodes). 0 if unknown.
    public var start: TimeInterval
    /// Length of this cue in seconds (for SRT end time). 0 if unknown.
    public var duration: TimeInterval

    public init(isYou: Bool, time: Date, text: String, isFinal: Bool,
                start: TimeInterval = 0, duration: TimeInterval = 0) {
        self.isYou = isYou; self.time = time; self.text = text; self.isFinal = isFinal
        self.start = start; self.duration = duration
    }
}

/// 「最近 3 分鐘」視窗過濾(UI-10/BUG-20)。錨定**最後一行的時間**而非牆鐘,
/// 讓 錄音中/結束後/舊檔轉稿 三種情境語意一致:永遠顯示「這份逐字稿的最後
/// windowSec 秒」;舊檔各行時間相同時退化成全顯(不會被濾成空白)。
public enum TranscriptWindow {
    public static func visible(_ lines: [TranscriptLine], full: Bool,
                               windowSec: TimeInterval = 180) -> [TranscriptLine] {
        guard !full, let last = lines.last?.time else { return lines }
        let cutoff = last.addingTimeInterval(-windowSec)
        return lines.filter { $0.time >= cutoff }
    }
}

public enum RecordingState: Equatable, Sendable {
    case idle        // 待錄音
    case recording   // 錄音中
    case paused      // 已暫停
    case finished    // 結束後
}
