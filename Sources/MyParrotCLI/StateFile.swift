import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `~/.config/myparrot/record.pid` + `state.json`(§2.2,§2.3)。
struct CLIRecordingState: Codable, Equatable {
    var pid: Int32
    var startedAt: String
    var audioPath: String
    var name: String
    /// "recording" | "paused" | "stopping" | "postprocessing"
    var state: String
    var levels: Levels
    var warning: String?
    var updatedAt: String

    struct Levels: Codable, Equatable {
        var other: Double
        var you: Double
        var otherSignal: Bool
        var youSignal: Bool

        init(other: Double = 0, you: Double = 0, otherSignal: Bool = false, youSignal: Bool = false) {
            self.other = other; self.you = you; self.otherSignal = otherSignal; self.youSignal = youSignal
        }
    }
}

/// 原子寫檔(temp 檔 + rename,同磁區 rename 是原子操作)——config/state 共用。
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

enum StateStore {
    static var pidfilePath: URL { CLIConfigStore.configDir.appendingPathComponent("record.pid") }
    static var statePath: URL { CLIConfigStore.configDir.appendingPathComponent("state.json") }

    /// stale 判定:`kill(pid, 0)` 失敗(ESRCH 等)→ 該 pid 已不存在。純函式化以
    /// 利 SelfTest(CLI-02:用自己的 pid 測「活的」、用 99999 一類極不可能存在
    /// 的 pid 測「stale」——真正嚴謹的偽陽性防呆留給 CLI-09 審查)。
    static func isStalePID(_ pid: Int32) -> Bool {
        kill(pid_t(pid), 0) != 0
    }

    static func readPID() -> Int32? {
        guard let s = try? String(contentsOf: pidfilePath, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 目前錄音中的 pid;stale pidfile 會被當場清掉(§2.2:「自動刪除並視同無
    /// 錄音」)。回傳 nil = 沒有錄音在跑。
    static func activePID() -> Int32? {
        guard let pid = readPID() else { return nil }
        if isStalePID(pid) {
            cleanup()
            return nil
        }
        return pid
    }

    static func writePID(_ pid: Int32) throws {
        try FileManager.default.createDirectory(at: CLIConfigStore.configDir, withIntermediateDirectories: true)
        try AtomicFile.write(Data(String(pid).utf8), to: pidfilePath)
    }

    static func writeState(_ state: CLIRecordingState) throws {
        try FileManager.default.createDirectory(at: CLIConfigStore.configDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try AtomicFile.write(data, to: statePath)
    }

    static func readState() -> CLIRecordingState? {
        guard let data = try? Data(contentsOf: statePath) else { return nil }
        return try? JSONDecoder().decode(CLIRecordingState.self, from: data)
    }

    /// 錄音進程正常退出時清兩檔(§2.3)。
    static func cleanup() {
        try? FileManager.default.removeItem(at: pidfilePath)
        try? FileManager.default.removeItem(at: statePath)
    }
}

/// ISO8601 字串工具——state.json/JSON 事件的時間欄位統一格式。`ISO8601DateFormatter`
/// 不是 Sendable,故不快取成 static let(Swift 6 嚴格併發下會報「共用可變狀態」);
/// 這裡的呼叫頻率(1Hz 級)重建一個 formatter 的成本可忽略。
enum ISO8601 {
    static func string(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
