import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// termios raw mode 共用機制(§9)。原本只服務 `InteractiveRecordingSession` 的
/// 錄音畫面單鍵輪詢(p/Enter/m,非阻塞 `pollKey()`);修 3(2026-08-10,Eric 實測
/// 回饋:編號選單按方向鍵印出 `^[[A` 垃圾字元)把這支檔案獨立出來,新增
/// `enableBlocking()`/`readMenuKey()` 給 `ArrowMenu` 用——兩種 raw mode 用途
/// 不同(錄音畫面要跟電平表重繪並行、非阻塞輪詢;選單導覽沒有並行工作,直接
/// 阻塞等一個鍵按下即可),故分開兩組 termios 設定函式,但 ECHO/ICANON 關閉、
/// enable/restore 對稱這些核心邏輯共用同一個型別。
enum RawMode {
    /// 非阻塞模式(VMIN=0/VTIME=0):錄音畫面用,搭配外層 100ms `Task.sleep`
    /// 輪詢,讓電平表重繪跟按鍵偵測交錯進行。
    static func enable() -> termios? {
        guard Output.isStdinTTY else { return nil }
        var oldt = termios()
        guard tcgetattr(STDIN_FILENO, &oldt) == 0 else { return nil }
        var newt = oldt
        newt.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        withUnsafeMutableBytes(of: &newt.c_cc) { raw in
            raw[Int(VMIN)] = 0
            raw[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &newt) == 0 else { return nil }
        return oldt
    }

    /// 阻塞模式(VMIN=1/VTIME=0):選單導覽用——選單沒有其他並行工作要顧,直接
    /// 等一個 byte 讀到為止,不用 spin loop 浪費 CPU。
    static func enableBlocking() -> termios? {
        guard Output.isStdinTTY else { return nil }
        var oldt = termios()
        guard tcgetattr(STDIN_FILENO, &oldt) == 0 else { return nil }
        var newt = oldt
        newt.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        withUnsafeMutableBytes(of: &newt.c_cc) { raw in
            raw[Int(VMIN)] = 1
            raw[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &newt) == 0 else { return nil }
        installSignalRestore(oldt)
        return oldt
    }

    static func restore(_ saved: termios) {
        var t = saved
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        uninstallSignalRestore()
    }

    // v0.3.0 GPT 二審(高):選單的 raw mode 只靠 `defer` 還原——Ctrl-C 走預設 SIGINT
    // 直接終止進程,defer 不會跑,shell 留在無 echo/非 canonical 狀態。這裡在
    // enableBlocking 期間掛一個 async-signal-safe 的 handler:先 tcsetattr 還原、
    // 再用預設動作重送同一個訊號(離開碼語意不變)。錄音畫面另有自己的 SIGINT
    // DispatchSource,不走這裡。
    nonisolated(unsafe) private static var originalForSignal = termios()
    nonisolated(unsafe) private static var signalRestoreInstalled = false
    private static func installSignalRestore(_ saved: termios) {
        originalForSignal = saved
        signalRestoreInstalled = true
        let handler: @convention(c) (Int32) -> Void = { sig in
            var t = RawMode.originalForSignal
            tcsetattr(STDIN_FILENO, TCSANOW, &t)
            signal(sig, SIG_DFL)
            raise(sig)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
        signal(SIGHUP, handler)
    }
    private static func uninstallSignalRestore() {
        guard signalRestoreInstalled else { return }
        signalRestoreInstalled = false
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
    }

    /// 非阻塞讀一個字元;沒有輸入回傳 nil。呼叫端要先 `enable()` 過。
    static func pollKey() -> Character? {
        var buf: UInt8 = 0
        let n = read(STDIN_FILENO, &buf, 1)
        guard n == 1 else { return nil }
        return Character(UnicodeScalar(buf))
    }

    /// 阻塞讀一個選單導覽事件。呼叫端須先 `enableBlocking()`。方向鍵是 ESC `[`
    /// A/B 三個 byte 的 escape sequence;單獨按 Esc(取消)沒有後續 byte——用
    /// 短逾時(VTIME=1≈100ms)讀第二個 byte 來分辨兩者(標準終端技巧:同一次
    /// 按鍵送出的多 byte 序列幾乎同時抵達,100ms 內收不到後續 byte 就代表是
    /// 單獨按鍵,不是 escape sequence 開頭)。只認單一數字鍵(1-9)直選,選單
    /// 項目數在這個 CLI 的實際場景(裝置/設定/最近錄音)都在個位數,多位數
    /// 選號留給非 TTY 的 fallback 路徑(它讀整行,天生支援多位數)。
    static func readMenuKey() -> MenuKey {
        guard let b = readByteBlocking() else { return .cancel }   // 理論上不會發生(已 enableBlocking),防禦性視同取消,不掛住
        switch b {
        case 0x1B:   // ESC
            guard let b2 = readByteWithShortTimeout(), b2 == UInt8(ascii: "[") else { return .cancel }
            guard let b3 = readByteWithShortTimeout() else { return .other }
            switch b3 {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            default: return .other
            }
        case 0x0D, 0x0A: return .confirm   // \r / \n
        case UInt8(ascii: "q"), UInt8(ascii: "Q"): return .cancel
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .digit(Int(b - UInt8(ascii: "0")))
        default:
            return .other
        }
    }

    private static func readByteBlocking() -> UInt8? {
        var buf: UInt8 = 0
        let n = read(STDIN_FILENO, &buf, 1)
        return n == 1 ? buf : nil
    }

    /// 暫時切到 VMIN=0/VTIME=1(≈100ms 逾時)讀一個 byte,讀完不論成功與否都
    /// 切回 VMIN=1/VTIME=0(阻塞模式),供下一次 `readMenuKey()` 呼叫使用——
    /// 呼叫端(`enableBlocking()`)的狀態機不因為這個內部探測被打亂。
    private static func readByteWithShortTimeout() -> UInt8? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var timeoutT = original
        withUnsafeMutableBytes(of: &timeoutT.c_cc) { raw in
            raw[Int(VMIN)] = 0
            raw[Int(VTIME)] = 1
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &timeoutT)
        var buf: UInt8 = 0
        let n = read(STDIN_FILENO, &buf, 1)
        var blockingT = original
        withUnsafeMutableBytes(of: &blockingT.c_cc) { raw in
            raw[Int(VMIN)] = 1
            raw[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &blockingT)
        return n == 1 ? buf : nil
    }
}

/// 選單導覽事件(`RawMode.readMenuKey()` 的回傳型別)。
enum MenuKey: Equatable {
    case up, down, confirm, cancel
    case digit(Int)
    case other
}

/// 通用「編號選單方向鍵導覽」(修 3)。給一組選項字串,回傳選到的 0-based
/// index 或取消;`tcsetattr` 失敗(非 TTY、或終端不支援 raw mode)回傳 nil,
/// 呼叫端自己 fallback 回舊版 `readLine()` 編號輸入——「取消」在不同呼叫端
/// 意義不同(有的是「用系統預設」,有的是「返回上一層」),故這個型別只回報
/// `.cancelled`,語意解讀交給呼叫端。
enum ArrowMenu {
    enum Outcome: Equatable { case index(Int); case cancelled }

    /// - title: 選單標題(可含操作提示,如「↑↓ 選擇,Enter 確認,q/Esc 返回」)。
    /// - items: 每個選項的顯示文字(不含編號前綴,這裡自動加 `1.`/`2.`…)。
    /// - initialIndex: 一進選單反白哪一項(預設第一項)。
    static func select(title: String, items: [String], initialIndex: Int = 0) -> Outcome? {
        guard Output.isStdinTTY else { return nil }
        guard !items.isEmpty else { return .cancelled }
        guard let saved = RawMode.enableBlocking() else { return nil }
        defer { RawMode.restore(saved) }

        var selected = min(max(0, initialIndex), items.count - 1)
        var previousLineCount = 0
        func draw() {
            var lines = title.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, item) in items.enumerated() {
                let marker = i == selected ? "❯" : " "
                let line = "\(marker) \(i + 1). \(item)"
                lines.append(i == selected ? Meter.colorize(line, code: "7", useColor: Output.useColor) : line)
            }
            var out = ""
            if previousLineCount > 0 {
                out += "\u{1B}[\(previousLineCount)A"
                for _ in 0..<previousLineCount { out += "\u{1B}[2K\r\n" }
                out += "\u{1B}[\(previousLineCount)A"
            }
            out += lines.joined(separator: "\n")
            print(out)
            fflush(stdout)
            previousLineCount = lines.count
        }

        draw()
        while true {
            switch RawMode.readMenuKey() {
            case .up:
                selected = (selected - 1 + items.count) % items.count
                draw()
            case .down:
                selected = (selected + 1) % items.count
                draw()
            case .confirm:
                print("")
                return .index(selected)
            case .digit(let d) where d >= 1 && d <= items.count:
                print("")
                return .index(d - 1)
            case .cancel:
                print("")
                return .cancelled
            case .digit, .other:
                continue   // 超出範圍的數字/其他鍵:忽略,選單原地不動
            }
        }
    }
}
