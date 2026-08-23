import Foundation
import MyParrotCore

/// 編號式麥克風選單(D10,§4.5)。非 TTY 絕不呼叫這裡——呼叫端(RecordCommand/
/// InteractiveMenu)負責先判斷 `Output.isStdinTTY`。
enum MicPicker {

    /// 純函式:裝置清單 → 顯示用標籤(藍牙/iPhone 標記同 GUI micLabel 語意)。
    static func label(for device: AudioInputDevice) -> String {
        var name = device.name
        if device.isBluetooth { name = "⚠️ \(name)(藍牙)" }
        else if device.isContinuity { name = "\(name)(iPhone)" }
        return name
    }

    enum PickResult {
        case device(AudioInputDevice)
        case systemDefault     // 空白 Enter/找不到裝置
        case noInput           // EOF/讀取失敗——呼叫端視為「不變更當下選擇」
    }

    /// 印選單、讀一行輸入、回傳選到的裝置。`readLineFn` 可注入測試(避免真的
    /// 等 stdin)。純函式部分=`label(for:)`;這裡含 I/O 副作用。
    ///
    /// 修 3(2026-08-10,Eric 實測回饋:按 ↑↓ 印出 `^[[A` 垃圾字元):TTY 時
    /// 優先走 `ArrowMenu` 方向鍵導覽,「取消」(q/Esc)對應這裡的
    /// `.systemDefault`(跟原本「空白 Enter=系統預設」同語意——放棄挑選特定
    /// 裝置,用系統預設)。`useArrowKeys: false` 給 `CLISelfTest` 注入假
    /// `readLineFn` 時關掉(測試環境不一定是真 TTY,也不該真的去 grab 終端
    /// raw mode);非 TTY、或 `tcsetattr` 失敗(`ArrowMenu.select` 回傳
    /// nil)一律 fallback 回這裡原本的 `readLine()` 編號模式,行為完全不變。
    static func pick(devices: [AudioInputDevice],
                      readLineFn: () -> String? = { readLine() },
                      useArrowKeys: Bool = true) -> PickResult {
        guard !devices.isEmpty else {
            Output.infoLine("(找不到任何輸入裝置,使用系統預設)")
            return .systemDefault
        }
        if useArrowKeys {
            let items = devices.map(label(for:))
            if let outcome = ArrowMenu.select(
                title: "選擇麥克風(↑↓ 選擇,Enter/數字確認,q/Esc=系統預設):", items: items) {
                switch outcome {
                case .index(let idx): return .device(devices[idx])
                case .cancelled: return .systemDefault
                }
            }
        }
        Output.infoLine("選擇麥克風(Enter=系統預設):")
        for (i, d) in devices.enumerated() {
            Output.infoLine("\(i + 1). \(label(for: d))")
        }
        guard let raw = readLineFn() else { return .noInput }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .systemDefault }
        guard let idx = Int(trimmed), idx >= 1, idx <= devices.count else {
            Output.errLine("輸入無效,沿用系統預設")
            return .systemDefault
        }
        return .device(devices[idx - 1])
    }
}
