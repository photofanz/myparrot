import Foundation

/// #949 第一段 REC-32:收割規則(取代 `resumePendingConversions`「看到 .caf 就轉」)。
/// 舊規則會把**別的進程正在寫的活檔**當成殘檔轉掉再刪(#949 的毀檔真兇);新規則:
/// - 頂層 `.caf`:只讀不動。mtime > 24 小時 ⇒ `.manualOnly`(列表給「修復」,使用者按了才轉);否則 `.skip`。
/// - `inprogress/<id>/audio.caf`:租約 `.alive` ⇒ `.skip`(活檔);`.dead`／沒有租約檔 ⇒ `.repair`
///   (發布到頂層加「-已修復」再轉);`.unreadable`(errno、卷不支援 advisory lock)⇒ `.failClosed`(不收割、回報)。
public enum ReapDecision: Equatable, Sendable {
    case skip
    case repair
    case manualOnly
    case failClosed
}

/// #949 第一段 REC-33:`convertToM4A` 遇到幀數太少的 caf ⇒ **搬到隔離區**並回錯誤,不再靜默刪檔。
/// (舊行為:`frames < 2400` 直接 `removeItem`——活檔被別的進程誤判成空檔時就這樣不見了。)
public enum ConversionDecision: Equatable, Sendable {
    case convert
    case quarantine
}

public enum ConversionPolicy {
    /// < 2400 幀(48k 下 0.05 秒)＝誤觸開始→停止,沒有內容;門檻沿用舊值。
    public static let minimumFrames: Int64 = 2_400

    public static func decide(frames: Int64) -> ConversionDecision {
        frames < minimumFrames ? .quarantine : .convert
    }

    /// UI／CLI 的錯誤訊息(繁中;GUI 依介面語言重組)。
    public static func quarantineMessage(frames: Int64) -> String {
        "錄音太短（\(frames) 幀），已移到隔離區"
    }

    /// `<dir>/.myparrot/quarantine/`
    public static func quarantineDir(dir: URL) -> URL {
        InprogressFiles.privateDir(dir: dir).appendingPathComponent("quarantine", isDirectory: true)
    }

    /// 把 caf 搬進 `<dir>/.myparrot/quarantine/<原檔名>`(撞名加「 2」…;絕不覆蓋、絕不刪)。回傳新位置。
    public static func quarantine(_ caf: URL, dir: URL, fm: FileManager = .default) throws -> URL {
        let qdir = quarantineDir(dir: dir)
        try fm.createDirectory(at: qdir, withIntermediateDirectories: true)
        let stem = caf.deletingPathExtension().lastPathComponent
        let ext = caf.pathExtension
        var dest = qdir.appendingPathComponent(caf.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = qdir.appendingPathComponent("\(stem) \(n).\(ext)"); n += 1
        }
        try fm.moveItem(at: caf, to: dest)
        return dest
    }
}

public enum ReapPolicy {
    /// 頂層殘檔手動修復門檻(brief §9 預設 24 小時)。
    public static let manualRepairAge: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - topLevelCafAge: 非 nil ⇒ 判的是頂層 `.caf`(值＝距 mtime 秒數);nil ⇒ 判 inprogress 檔。
    ///   - inspection: 判 inprogress 檔時的租約觀察結果(頂層 `.caf` 不看租約:舊版 writer 沒有租約)。
    public static func decide(topLevelCafAge: TimeInterval?, inspection: LeaseInspection?) -> ReapDecision {
        if let age = topLevelCafAge {
            return age > manualRepairAge ? .manualOnly : .skip
        }
        switch inspection {
        case .alive?: return .skip
        case .dead?, .none?: return .repair
        case .unreadable?: return .failClosed
        case nil: return .failClosed   // 沒觀察到就不動(fail closed)
        }
    }
}
