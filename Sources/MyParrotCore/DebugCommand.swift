import Foundation

/// #2412 DEBUG 控制通道的**純決策**部分(DBG-01):指令字串怎麼切、結果檔可以寫去哪。
/// 放 Core 是為了讓 SelfTest 驗得到;真正收指令、動 UI 的 `DebugControl` 在 app target
/// 且整檔 `#if DEBUG`,release 不含。這裡沒有任何副作用。
public enum DebugCommand {
    /// 參數分隔字元(ASCII Unit Separator),指令本身不可能含它。
    public static let separator: Character = "\u{1F}"

    /// 切參數:空參數保留(`a\u{1F}\u{1F}b` → ["a","","b"]),整串空字串 → []。
    public static func parse(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }

    /// 結果檔只准寫到暫存區或家目錄底下(DBG-01/06):絕對路徑、不含 `..`、
    /// 前綴是 /tmp、/private/tmp、$TMPDIR(含 /private/var/folders)或家目錄。
    public static func isAllowedResultPath(_ path: String,
                                           home: String = NSHomeDirectory(),
                                           tmp: String = NSTemporaryDirectory()) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        var roots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        for r in [tmp, home] where !r.isEmpty { roots.append(r.hasSuffix("/") ? r : r + "/") }
        return roots.contains { path.hasPrefix($0) }
    }
}
