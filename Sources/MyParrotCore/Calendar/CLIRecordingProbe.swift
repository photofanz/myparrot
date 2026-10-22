import Foundation

/// #949(一邊錄音時不要啟動另一邊):GUI 從通知按鈕開錄前,先看 CLI 是不是正在錄。
/// 依據＝CLI 的 `~/.config/myparrot/record.pid`(StateFile.swift §2.2)還活著。
/// 只讀不寫;pid 檔殘留但行程已死 → 視為沒在錄(CLI 自己會清 stale pidfile)。
public enum CLIRecordingProbe {
    public static var pidURL: URL { FiredReminderStore.configDir.appendingPathComponent("record.pid") }

    public static func isCLIRecording(pidURL: URL = pidURL) -> Bool {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = parsePID(text), pid > 0 else { return false }
        return isAlive(pid)
    }

    /// 純函式:pid 檔內容 → pid(容忍尾端換行與空白;非數字 → nil)。
    public static func parsePID(_ text: String) -> Int32? {
        Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // 存在但不是自己的 → 也算活著
    }
}
