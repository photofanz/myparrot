import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// ANSI 電平表渲染(§4.4,D3)。手刻零依賴,仿 sox `rec` VU meter。純函式(格數/
/// dB 計算)與有副作用的重繪分開,前者給 SelfTest 覆蓋。
enum Meter {

    /// 終端寬度(`ioctl TIOCGWINSZ`),失敗回 80(常見預設)。
    static func terminalWidth() -> Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 {
            return Int(w.ws_col)
        }
        return 80
    }

    /// bar 寬度:min(40, 終端寬-20)(§4.4),下限 10 避免極窄終端算出負值。
    static func barWidth(terminalWidth: Int = terminalWidth()) -> Int {
        min(40, max(10, terminalWidth - 20))
    }

    /// level(0...1) → bar 格數。**規則:level>0.005 時至少 1 格**(UI-22 教訓:
    /// 純線性映射在低電平時會整條全空,使用者以為完全沒收到聲音)。純函式。
    static func barCells(level: Float, width: Int) -> Int {
        guard width > 0 else { return 0 }
        let clamped = max(0, min(1, level))
        if clamped <= 0 { return 0 }
        let raw = Int((clamped * Float(width)).rounded())
        if clamped > 0.005 && raw == 0 { return 1 }
        return min(width, max(0, raw))
    }

    static func barString(level: Float, width: Int, filled: Character = "█", empty: Character = "░") -> String {
        let cells = barCells(level: level, width: width)
        return String(repeating: filled, count: cells) + String(repeating: empty, count: max(0, width - cells))
    }

    /// 0...1 線性電平 → dB 顯示字串(近似,只供人讀)。
    static func dBString(_ level: Float) -> String {
        guard level > 0.0001 else { return "-∞dB" }
        let db = 20 * log10(level)
        return String(format: "%.0fdB", db)
    }

    // MARK: - ANSI 顏色(NO_COLOR 尊重由呼叫端傳 useColor 決定)

    static func colorize(_ s: String, code: String, useColor: Bool) -> String {
        useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static let redCode = "31"
    static let blueCode = "34"
    static let yellowCode = "33"
    static let redBgCode = "41;97"   // 紅底白字,死聲道警示

    struct Frame {
        var otherLevel: Float
        var youLevel: Float
        var otherHasSignal: Bool
        var youHasSignal: Bool
        /// 死聲道判定用:距最後一次真訊號多久(秒)。>2s 才轉紅底(§4.4)。
        var otherSilentFor: TimeInterval
        var youSilentFor: TimeInterval
        var elapsed: TimeInterval
        var name: String
        var warning: String?
        var lastError: String?
    }

    /// 產生一次重繪的完整文字區塊(含清行/上移的 ANSI 控制碼)。`previousLineCount`
    /// =上一輪畫了幾行,才知道要上移幾行再清;回傳新的行數供下一輪使用。
    static func render(_ frame: Frame, useColor: Bool, previousLineCount: Int) -> (text: String, lineCount: Int) {
        let width = barWidth()
        let otherWarn = frame.otherSilentFor > 2 && frame.elapsed > 2
        let youWarn = frame.youSilentFor > 2 && frame.elapsed > 2

        var lines: [String] = []
        let elapsedStr = formatElapsed(frame.elapsed)
        lines.append("🦜 \(frame.name.isEmpty ? "錄音中" : frame.name)  \(elapsedStr)")

        if otherWarn {
            lines.append(colorize("⚠ 對方軌無訊號", code: redBgCode, useColor: useColor))
        } else {
            let bar = barString(level: frame.otherLevel, width: width)
            let line = "對方 ▕\(bar)▏ \(dBString(frame.otherLevel))"
            lines.append(colorize(line, code: redCode, useColor: useColor))
        }

        if youWarn {
            lines.append(colorize("⚠ 你的麥克風無訊號", code: redBgCode, useColor: useColor))
        } else {
            let bar = barString(level: frame.youLevel, width: width)
            let line = "你   ▕\(bar)▏ \(dBString(frame.youLevel))"
            lines.append(colorize(line, code: blueCode, useColor: useColor))
        }

        if let warning = frame.warning {
            lines.append(colorize(warning, code: yellowCode, useColor: useColor))
        }
        if let lastError = frame.lastError {
            lines.append(colorize("錯誤:\(lastError)", code: yellowCode, useColor: useColor))
        }

        var out = ""
        if previousLineCount > 0 {
            out += "\u{1B}[\(previousLineCount)A"
            for _ in 0..<previousLineCount { out += "\u{1B}[2K\r\n" }
            out += "\u{1B}[\(previousLineCount)A"
        }
        out += lines.joined(separator: "\n")
        return (out, lines.count)
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
