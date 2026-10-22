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
    /// #949 REC-32:頂層殘留的 `.caf`(舊版 writer 的活檔或中斷檔)——**只讀不動**,列表標「未完成錄音,右鍵修復」;
    /// mtime 超過 24 小時才給「修復」(那時才呼叫轉檔)。本進程自己正在轉的 caf 不算。
    public var needsManualRepair: Bool

    public init(id: UUID, title: String, url: URL, date: Date,
                duration: TimeInterval, hasTranscript: Bool,
                isConverting: Bool = false, needsManualRepair: Bool = false) {
        self.id = id; self.title = title; self.url = url; self.date = date
        self.duration = duration; self.hasTranscript = hasTranscript
        self.isConverting = isConverting
        self.needsManualRepair = needsManualRepair
    }

    /// #949:收割端把死掉的 inprogress 復原到頂層時的檔名:`<stem>-已修復.caf`(英文介面也用,檔名不隨語言)。
    public static func repairedFileName(stem: String) -> String { "\(stem)\(repairedSuffix).caf" }
    public static let repairedSuffix = "-已修復"

    /// 同名逐字稿 sidecar(`.txt`);`hasTranscript` 即此檔存在。
    public var transcriptURL: URL { url.deletingPathExtension().appendingPathExtension("txt") }

    /// 錄音**起始**時刻:掃描進來的 `date` 是檔案 mtime(=結束時刻),載入舊稿要把每句的
    /// 偏移秒數加回起點才會顯示正確的牆鐘時間(10/22 截圖抓到:載入舊稿每句都顯示「08:00」,
    /// 因為 `SRT.parse` 用 epoch 當 time)。先從檔名範本 `yyyy-MM-dd HHmm` 解析,解不出就用
    /// mtime 減時長。
    public var startDate: Date { Self.startDate(fromFileName: url.lastPathComponent) ?? date.addingTimeInterval(-duration) }

    /// 純函式:`"2026-10-22 1500 產品週會.m4a"` → 2026-10-22 15:00(本地時區);不符範本回 nil。
    public static func startDate(fromFileName name: String) -> Date? {
        guard name.count >= 15 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.date(from: String(name.prefix(15)))
    }

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
        let t = cleanedTitle(title)
        return t.isEmpty ? "錄音" : t
    }

    /// `sanitizeTitle` 的清理步驟本體,**不帶**空字串 fallback(#2438 UI-53:改名要能分辨
    /// 「清完是空的」⇒ 拒絕,而不是默默改成「錄音」)。
    static func cleanedTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = String(String.UnicodeScalarView(t.unicodeScalars.filter { $0.properties.generalCategory != .control }))
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while t.utf8.count > 120 { t.removeLast() }
        return t
    }

    /// 錄音/逐字稿/筆記/會議記錄會長出的副檔名——探測檔名衝突時全部算(#892)。
    /// #2438 起單一真相在 `SidecarSet.extensions`(多了 notes.md／minutes.md／minutes.json／zh-Hant.srt),這裡轉呼叫。
    public static let derivedExtensions: [String] = SidecarSet.extensions

    /// #892:同一分鐘同標題兩次錄音會算出同檔名 → 第二次靜默覆蓋第一次。
    /// 在 `dir` 內探測同 stem 的任一衍生檔存在就加 Finder 式後綴「 2」「 3」…;
    /// 無衝突時與 `fileName` 完全相同(REC-01 範本不變)。
    /// 跨進程(#949 第一段起的實況):全域租約 `recording.lease` 保證同時只有一個新版 writer;錄音寫在
    /// `.myparrot/inprogress/<sessionId>/`,這裡算出的名字只是「預定發布名」,停止時
    /// `RecordingController.publishInprogress` 再探一次(只看音檔)並用 `renamex_np(RENAME_EXCL)` 發布——
    /// 跟舊版 writer 同分鐘同標題撞名時換下一個後綴,絕不覆蓋。
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
