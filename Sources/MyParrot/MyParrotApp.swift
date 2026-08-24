import SwiftUI
import AppKit
import MyParrotCore

@main
struct MyParrotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = RecordingController()
    // UI-25: 三態視窗模式(標準／窄版／迷你)單一真相,取代原本的 miniMode 布林。
    @State private var windowMode = WindowModeManager()
    // UPD:掛在 Group 而非 RootView——模式切換不會取消/重跑這個 3 秒延遲檢查。
    @State private var updates = UpdateChecker()
    // UI-24: 選單命令(在 view 樹外)與 RootView 都要讀寫的狀態(設定 sheet、
    // 逐字稿範圍、列表收折)——集中成一個 @Observable 匯流排注入 environment,
    // 不用 NotificationCenter 亂飛(Eric 明確指定的作法)。
    @State private var uiState = AppUIState()

    var body: some Scene {
        WindowGroup("MyParrot") {
            Group {
                if windowMode.mode == .mini {
                    MiniView(controller: controller, windowMode: windowMode)
                } else {
                    RootView(controller: controller, updates: updates,
                              uiState: uiState, windowMode: windowMode)
                }
            }
            // UI-20: 視窗最小尺寸的**單一真相**(RootView 不再自帶 frame——雙重約束
            // 取大者,曾讓 RootView 的 320 被這裡的舊 720 蓋掉而失效)。
            // UI-34(Eric 2026-08-24 09:05):320 → 380——狀態列「待錄音 00:00:00」+
            // 模式/設定兩鈕單列所需寬度(真機二分實測臨界 370,+10 安全邊際);
            // 最小寬度保證不觸發 ViewThatFits 兩列退版(退版程式保留,當非中文
            // 語系狀態字較寬時的保險)。
            // UI-21 v4: minHeight 620——逐字稿/列表間改 VSplitView 可拖曳分隔後,
            // 內容下限=控制卡+逐字稿 pane min 140+列表 pane min 88+adBar;620 保證
            // footer 兩行完整、其餘比例使用者自己拖(不再硬寫死列表高度)。
            // UI-25: 窄版(compact)沿用同一組 380/620——WindowModeManager 把窄版
            // 釘死在這個下限上,兩者本就該是同一個數字,不新增第三組。
            .frame(minWidth: windowMode.mode == .mini ? 300 : 380,
                   minHeight: windowMode.mode == .mini ? 60 : 620)
            .onAppear {
                appDelegate.controller = controller
                // UI-25: 啟動套一次自存模式/frame,之後不再干預使用者拖拉/並排。
                windowMode.applyInitialFrame()
            }
            // UPD:啟動 3 秒後背景查一次更新(避開啟動關鍵路徑/權限請求),失敗靜默。
            .task { try? await Task.sleep(for: .seconds(3)); await updates.autoCheckAtLaunch() }
        }
        .windowResizability(.contentSize)
        // UI-21: 移除 hiddenTitleBar(它把內容拉進標題列、與工具列疊字=Eric 回報的
        // header overlap)。改用原生標題列(內容乾淨落在其下),迷你/設定兩鈕移進內容
        // 首列的 statusCard(見 RootView),不再靠 macOS 工具列(窄視窗會收「»」)。
        .commands {
            // UPD:App menu 加「檢查更新…」(macOS 慣例位置),無視 enabled/skip。
            CommandGroup(after: .appInfo) {
                Button(L("檢查更新…")) { Task { await updates.checkNow() } }
            }
            // UI-24:App menu「設定… ⌘,」+ CommandMenu「錄音」「顯示方式」。
            AppCommands(controller: controller, uiState: uiState, windowMode: windowMode)
        }
    }
}

/// UI-24: cross-cutting UI state the `.commands` menu (outside the view
/// hierarchy) and RootView both need to read/write. Centralizing this here
/// (instead of NotificationCenter, instead of duplicating @State in both
/// places) is what lets a menu click or ⌘L/⌘K actually move RootView's UI.
@MainActor
@Observable
final class AppUIState {
    var showSettings = false
    var fullTranscript = false
    var listExpanded = true
}

/// UI-24: the「錄音」/「顯示方式」menus + the App-menu's「設定…」item, and
/// `CommandGroup(replacing: .newItem)` for「新錄音」(so ⌘N stops opening a
/// second WindowGroup window — see WindowModeManager's doc comment on why
/// that made the single-window NSApp.windows lookup safe).
/// Enable/disable rules follow docs/worklogs/2026-08-23-shortcuts/plan.md
/// 定稿:設定 sheet 開啟時停用 ⌘R/⌘N,錄音中的 ⌘P/⌘E 仍可用。2026-08-23 二審後
/// 追加:⌘1(切換模式)也一併停用——定稿原文沒提到這顆,但雙審都指出它會繞過
/// sheet 的視窗保護(見「切換模式」按鈕旁註解),不停用會有真實副作用,不是
/// 單純「跟規格不一致」可以放著不管的落差。
struct AppCommands: Commands {
    var controller: RecordingController
    var uiState: AppUIState
    var windowMode: WindowModeManager

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("新錄音")) { controller.newRecording() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(controller.state != .finished || uiState.showSettings)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L("設定…")) { uiState.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu(L("錄音")) {
            Button(L("開始錄音")) { controller.startRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(controller.state == .idle || controller.state == .finished) || uiState.showSettings)
            // 二審 Finding 3(HIG):選單原本固定印「暫停／繼續」,跟 ControlBar
            // 按鈕/help() 的動態文字對不上——仿照下面「收折/展開最近錄音」的寫法,
            // 依狀態即時換字。
            Button(controller.state == .paused ? L("繼續") : L("暫停")) {
                if controller.state == .recording { controller.pause() }
                else if controller.state == .paused { controller.resume() }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!(controller.state == .recording || controller.state == .paused))
            Button(L("結束錄音")) { controller.stop() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!(controller.state == .recording || controller.state == .paused))
            Divider()
            Button(L("轉逐字稿")) {
                if let last = controller.recordings.first { controller.transcribe(last) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(controller.recordings.isEmpty || controller.state == .recording)
            Button(L("在 Finder 打開")) {
                NSWorkspace.shared.activateFileViewerSelecting([controller.recordingsDir])
            }
            .keyboardShortcut("o", modifiers: .command)
            Divider()
            // UI-27(v2 定稿):「從頭播放」次要動作——無 ⌘ 快捷鍵(Phase 2 再議),
            // 只在有使用中的播放器時啟用。
            Button(L("從頭播放")) { controller.restartPlayback() }
                .disabled(controller.playingURL == nil)
        }
        CommandMenu(L("顯示方式")) {
            // 兩份二審都點出:這顆按鈕原本沒有 .disabled(uiState.showSettings),
            // 而 App-level .commands 不像 RootView 本地按鈕那樣天生被 sheet 擋掉
            // key window(見 notes.md 決策 3)——設定 sheet 開著時按 ⌘1 仍會呼叫
            // cycle(),輕則把 setFrame() 套到錯的視窗、重則讓 sheet 的 owner view
            // (RootView)被 mini 模式整個拔掉。跟 ⌘R/⌘N 用同一套規則擋掉。
            Button(L("切換模式")) { windowMode.cycle() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(uiState.showSettings)
            Divider()
            Button(L("逐字稿 3 分鐘／完整")) { uiState.fullTranscript.toggle() }
                .keyboardShortcut("l", modifiers: .command)
            Button(uiState.listExpanded ? L("收折最近錄音") : L("展開最近錄音")) {
                uiState.listExpanded.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(windowMode.mode == .mini)
        }
    }
}

/// Intercepts quit while a recording is in progress so it isn't lost. Default
/// action keeps recording; choosing to quit stops & saves first (the CAF is
/// finalized synchronously in stop(); m4a conversion resumes on next launch).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: RecordingController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = controller, c.state == .recording || c.state == .paused else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("錄音還在進行中")
        alert.informativeText = L("要先結束並儲存這段錄音,還是繼續錄音?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("繼續錄音"))        // first button = default (Return)
        alert.addButton(withTitle: L("結束錄音並離開"))
        if alert.runModal() == .alertFirstButtonReturn {
            return .terminateCancel                      // 繼續錄音
        }
        c.stop()                                         // 存檔後離開
        return .terminateNow
    }
}

// Shared formatting + palette.
enum MP {
    // UI-22 Phase C: 品牌色深色模式提高明度/飽和度(淺色底下的飽和色到深色底
    // 會顯髒灰);用 NSColor dynamicProvider 讓同一個 Color 依系統外觀自動切換,
    // 不用 xcassets(SwiftPM 加 resources 要動 Package.swift,越界)。
    private static func dynamicColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0)
        }))
    }

    static let blue = dynamicColor(light: (0.216, 0.541, 0.867), dark: (0.32, 0.62, 0.93))   // 你 / brand
    static let coral = dynamicColor(light: (0.847, 0.353, 0.188), dark: (0.91, 0.45, 0.30))  // 對方
    static let recRed = dynamicColor(light: (0.639, 0.176, 0.176), dark: (0.85, 0.32, 0.32))

    // Stronger, clearly-visible lines (the faint 0.5px ones were hard to read).
    static let line = Color.primary.opacity(0.22)
    static let strongLine = Color.primary.opacity(0.32)
    static func card(_ scheme: ColorScheme) -> Color { Color.primary.opacity(0.04) }

    // UI-22:8pt 網格間距 tokens——外層/卡內/row 各處各寫一個數字改成這 4 階,
    // 0-12 之間的雜數(1/2/3/6/9/10/11)就近併過來(平手取大)。
    static let spXS: CGFloat = 4
    static let spS: CGFloat = 8
    static let spM: CGFloat = 12
    static let spL: CGFloat = 16

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// UI-22:字級 tokens——5 階就近映射全 UI 既有的字級數字寫法
/// (9/10/11→caption;12→label;13/14→body;15/16→title;20→display),
/// 收斂成統一字級語言而非各處各寫一個 size/weight。icon-only 鈕(pip/gear)
/// 的 14pt 是視覺尺寸不是文字,刻意不收斂,見 RootView 該處註解。
enum MPFont {
    static let display = Font.system(size: 18, weight: .semibold, design: .monospaced) // 計時器(20→18 拉近級距)
    static let title   = Font.system(size: 15, weight: .semibold)   // 卡片/Sheet 標題
    static let body    = Font.system(size: 13)                      // 內文/按鈕
    static let label   = Font.system(size: 12, weight: .medium)     // 狀態/列表標題輔助
    static let caption = Font.system(size: 11)                      // 副標/meta
}

/// Shared mic-picker label: ⚠️ for Bluetooth (avoid), (iPhone) for Continuity.
/// Used by both the Settings picker and the main-screen quick picker so the
/// two never disagree about how a device is marked.
@MainActor func micLabel(_ d: AudioInputDevice) -> String {
    if d.isBluetooth { return "⚠️ \(d.name)" + L("(藍牙)") }
    if d.isContinuity { return "\(d.name)" + L("(iPhone)") }
    return d.name
}
