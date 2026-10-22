import Foundation
import MyParrotCore
#if canImport(Darwin)
import Darwin
#endif

/// TTY 偵測／NO_COLOR／--json 事件流輸出／exit code(§2.4,§2.5)。全模組唯一
/// 對 stdout/stderr 寫東西的地方,方便日後統一改行為。
enum Output {

    /// stdout 是否接到真終端機(而非 pipe/redirect)。
    static var isStdoutTTY: Bool { isatty(STDOUT_FILENO) != 0 }
    /// stdin 是否接到真終端機——雙軌分派/MicPicker 用來判斷能不能安全等輸入。
    static var isStdinTTY: Bool { isatty(STDIN_FILENO) != 0 }

    static var noColorEnv: Bool {
        let v = ProcessInfo.processInfo.environment["NO_COLOR"]
        return v != nil && !(v!.isEmpty)
    }

    /// 是否該輸出 ANSI 顏色碼:僅 TTY 且未設 NO_COLOR。非 TTY 一律零 ANSI(clig.dev)。
    static var useColor: Bool { isStdoutTTY && !noColorEnv }

    /// 錯誤/診斷一律走 stderr,不干擾 stdout 的資料面(--json 事件流)。
    static func errLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// 一般人讀訊息:非 --json 模式才印(quiet 模式由呼叫端自行判斷是否跳過)。
    static func infoLine(_ s: String) {
        print(s)
    }

    /// 一行一個 JSON event 寫 stdout,並立即 flush——agent 可能逐行即時讀(非等
    /// process 結束後一次讀完),行緩衝/全緩衝都可能延遲交付。
    static func jsonEvent(_ fields: [String: Any?]) {
        print(JSONLine.encode(fields))
        fflush(stdout)
    }

    // MARK: - #949 第一段新事件

    /// `record` 遇到別人持有租約:`{"event":"refused","reason":"gui-recording","sessionId":…,"name":…,"elapsed":12.3}`。
    static func refused(reason: String, lease: RecordingLease, elapsed: Double) {
        jsonEvent(["event": "refused", "reason": reason, "sessionId": lease.sessionId, "name": lease.name,
                   "owner": lease.owner, "pid": Int(lease.pid), "elapsed": elapsed])
    }

    /// `stop` 對象是 GUI owner(走 commands/ 指令檔):`{"event":"external","owner":"gui","action":"stop","result":"done"|"failed"|"timeout",…}`。
    static func external(action: String, lease: RecordingLease, result: String, detail: String? = nil) {
        jsonEvent(["event": "external", "owner": lease.owner, "action": action, "sessionId": lease.sessionId,
                   "name": lease.name, "result": result, "detail": detail])
    }

    /// 收割端把死掉的 inprogress 復原成頂層成品:`{"event":"recovered","sessionId":…,"audioPath":…}`。
    static func recovered(sessionId: String, audioPath: String) {
        jsonEvent(["event": "recovered", "sessionId": sessionId, "audioPath": audioPath])
    }
}

/// 純函式 JSON 單行編碼——沒有依賴 JSONSerialization 的巢狀型別限制,方便給
/// SelfTest 表驅動驗證(CLI-01)。只支援 --json 事件流需要的純量欄位型別。
enum JSONLine {
    static func encode(_ fields: [String: Any?]) -> String {
        var parts: [String] = []
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard let value else { continue }   // nil 欄位整個略過,不輸出 null(事件表精簡)
            parts.append("\(escapeString(key)):\(encodeValue(value))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func encodeValue(_ value: Any) -> String {
        switch value {
        case let s as String: return escapeString(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int32: return String(i)
        case let d as Double: return formatNumber(d)
        case let f as Float: return formatNumber(Double(f))
        // #949:status 的 `recoverable` 是物件陣列——支援一層巢狀(物件/陣列),nil 欄位同樣略過。
        case let obj as [String: Any?]: return encode(obj)
        case let obj as [String: Any]: return encode(obj.mapValues { Optional($0) })
        case let arr as [Any]: return "[" + arr.map(encodeValue).joined(separator: ",") + "]"
        default: return escapeString("\(value)")
        }
    }

    private static func formatNumber(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.4f", d)
    }

    static func escapeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// 全 CLI 統一 exit code(§2.4)。刻意跟 ArgumentParser 內建的 ExitCode 分開命名
/// 避免混淆(它的 exit code 用在旗標解析失敗,走預設的 2)。
enum MPExitCode: Int32 {
    case success = 0
    case argumentError = 2
    case permissionDenied = 3
    case recordingFailed = 4
    case transcriptionFailed = 5
    case hookFailedStrict = 6

    /// exit(code) 的薄包裝,呼叫端不用記 rawValue。
    func terminate() -> Never {
        exit(rawValue)
    }
}
