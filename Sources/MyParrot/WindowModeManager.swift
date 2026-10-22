import AppKit
import MyParrotCore
import Observation

/// UI-25: the three window modes ⌘1 cycles through.
enum WindowMode: String, Sendable {
    case standard   // 標準視窗(記住 frame)
    case compact    // 窄版視窗(380×620,左上角錨定;UI-34 320→380 配合單列狀態列;#2438 M4 只剩左欄)
    case mini       // 迷你控制列

    var icon: String {
        switch self {
        case .standard: return "macwindow"
        case .compact:  return "rectangle.arrowtriangle.2.inward"
        case .mini:     return "pip"
        }
    }

    var next: WindowMode {
        switch self {
        case .standard: return .compact
        case .compact:  return .mini
        case .mini:     return .standard
        }
    }
}

/// UI-25: drives the ⌘1 three-way window-mode cycle and owns the one piece of
/// window geometry the app persists itself — standard mode's frame — so a
/// relaunch restores it even when macOS's own window-state restoration (or a
/// tiling/"fill" gesture left in place) would otherwise win (2026-08-23 12:27
/// Eric 回報:並排填滿後重開沒回到自存大小).
///
/// Window lookup: chose `NSApp.windows.first { $0.contentView != nil &&
/// !$0.isSheet }` over an NSViewRepresentable window-accessor. Reason: ⌘N no
/// longer opens a second WindowGroup window (see CommandGroup(replacing:
/// .newItem) in MyParrotApp), so this app now has exactly one content window
/// at any time — a single lookup is unambiguous, and avoids threading a
/// hidden NSViewRepresentable through the view tree just to capture a window
/// reference. (Task instruction: "擇穩定者並在 notes 記理由" — recorded here
/// and in docs/worklogs/2026-08-23-shortcuts/notes.md.)
///
/// 2026-08-23 二審後修正:原本多篩了 `$0.isVisible`,在 `.onAppear` 這個時間
/// 點(冷啟動、`.windowResizability(.contentSize)` 還在算 ideal size)不保證
/// 視窗已被標成 visible——命中的話 `applyInitialFrame()` 會靜默 no-op,重演
/// 12:27 那個「填滿後重開沒回到自存大小」的 bug。拿掉 `isVisible`,只留
/// `contentView != nil`(SwiftUI 呼叫 `.onAppear` 前 contentView 必定已存在)
/// 直接解掉這個 race,不必再靠下一輪 runloop 的 async 延遲。新增
/// `!$0.isSheet`:改用「不篩 isVisible」後,設定 sheet 開著時它也會落在
/// `NSApp.windows` 裡且 `contentView != nil`,若 `cycle()` 挑到它會誤把
/// setFrame() 套到 sheet 視窗而非主視窗——因此排除 sheet 視窗;呼叫端(App
/// menu「切換模式」)另外用 `.disabled(uiState.showSettings)` 擋掉這條路徑,
/// 兩層防線疊加,任一層失守另一層仍擋得住。
@MainActor
@Observable
final class WindowModeManager {
    private static let modeKey = "windowMode"
    private static let frameKey = "windowFrame.standard"
    // #2438 M4:M3 的 760 過渡收回 620(逐字稿移到直欄,窄版只剩左欄;plan §3.4)。
    private static let compactSize = NSSize(width: 380, height: 620)

    var mode: WindowMode

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let saved = WindowMode(rawValue: raw) {
            mode = saved
        } else {
            mode = .standard
        }
    }

    /// Call once at launch (after the content window exists) to apply the
    /// persisted mode's geometry. Never called again during the session —
    /// mid-session resizing/tiling by the user is left alone; only launch
    /// forces our own frame back (GPT review 採納:只在啟動時套自存 frame,
    /// 執行中不干預使用者拖拉/並排).
    func applyInitialFrame() {
        guard let window = currentWindow() else {
            // 二審 Finding 1 要求的最低限度:這條路徑以前完全靜默,無法診斷。
            print("[WIN] applyInitialFrame(): currentWindow() 回傳 nil,啟動未套自存 frame/mode")
            return
        }
        switch mode {
        case .standard:
            if let frame = savedStandardFrame() { window.setFrame(Self.clampToScreens(frame), display: true) }
        case .compact:
            applyCompactFrame(to: window)
        case .mini:
            break   // MiniView 的最小內容尺寸自然決定視窗大小,不特別處理
        }
    }

    /// ⌘1 / the mode-toggle button: standard → compact → mini → standard.
    func cycle() {
        // v0.3.0 二審:找不到視窗就不要動 mode/UserDefaults(原本先改狀態再 return,
        // 畫面與幾何不一致且重啟後還記成新模式)。
        guard let window = currentWindow() else { return }
        // 離開 standard 時存 frame——僅在「主動切走」這一刻存,不隨時監聽
        // resize(否則使用者把視窗拖去填滿螢幕、卻從未切模式,下次啟動會把
        // 那個填滿的 frame 誤存成「自存好的大小」,重演 12:27 那個 bug)。
        if mode == .standard { saveStandardFrame(window.frame) }
        let target = mode.next
        mode = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.modeKey)
        switch target {
        case .standard:
            if let frame = savedStandardFrame() { window.setFrame(Self.clampToScreens(frame), display: true) }
        case .compact:
            applyCompactFrame(to: window)
        case .mini:
            break
        }
    }

    /// BUG-31:自存 frame 可能來自別的螢幕配置(外接螢幕時存的 x=1685),套之前夾回目前螢幕的可見區。
    private static func clampToScreens(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let primary = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? frame
        return WindowFrameClamp.clamp(frame, screens: screens, primary: primary)
    }

    /// 380×620,保持左上角不動(高度變小/變大都從底部伸縮)。
    private func applyCompactFrame(to window: NSWindow) {
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        var frame = NSRect(origin: .zero, size: Self.compactSize)
        frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - Self.compactSize.height)
        window.setFrame(frame, display: true)
    }

    private func saveStandardFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

    private func savedStandardFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: Self.frameKey) else { return nil }
        let r = NSRectFromString(s)
        return r == .zero ? nil : r
    }

    /// #2438 A1(UI-47):面板操作(開關欄、拉欄寬、停靠)後由 `WorkspaceView` 算好 frame
    /// (`WorkspaceLayout.resolve`)再套進來。只在標準模式動;跟現在一樣就不動(避免空動畫)。
    /// 使用者自己拖視窗邊不會走到這裡。
    func applyWorkspaceFrame(_ frame: NSRect, animate: Bool = true) {
        guard mode == .standard, let window = currentWindow() else { return }
        let cur = window.frame
        let same = abs(cur.minX - frame.minX) < 0.5 && abs(cur.minY - frame.minY) < 0.5
            && abs(cur.width - frame.width) < 0.5 && abs(cur.height - frame.height) < 0.5
        guard !same else { return }
        window.setFrame(frame, display: true, animate: animate)
    }

    /// 主視窗所在螢幕的可見區(A1 的「螢幕可見區」;多螢幕時是視窗所在那台)。
    func currentVisibleFrame() -> NSRect? {
        guard let window = currentWindow() else { return nil }
        return (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }

    func currentWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && !$0.isSheet }
    }
}
