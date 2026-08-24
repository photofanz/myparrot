import SwiftUI
import AppKit
import MyParrotCore

/// UI-22 Phase B:三種警示 banner(裝置變更警告/權限提示/錯誤)共用同一份材質底
/// +左側 4pt 色條語言,取代原本三處各自複製的 background(色.opacity)+overlay stroke。
private struct MPBannerStyle: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .padding(MP.spS)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func mpBanner(color: Color) -> some View { modifier(MPBannerStyle(color: color)) }
}

struct RootView: View {
    @Bindable var controller: RecordingController
    @Bindable var updates: UpdateChecker
    // UI-24: 設定 sheet／逐字稿範圍／列表收折搬進共用的 AppUIState——選單命令
    // (在 view 樹外)才能驅動這些狀態,見 MyParrotApp.AppUIState。
    @Bindable var uiState: AppUIState
    let windowMode: WindowModeManager
    @State private var loc = Localizer.shared
    // UPD:〔×〕=本次啟動不再顯示(不持久化,重啟再現)。
    @State private var updateBannerDismissed = false
    /// UI-22:錄音中狀態紅點呼吸動畫的驅動值(見 statusCard)。
    @State private var recDotBreathe = false
    /// UI-22:會議名稱欄位改 .plain 樣式後,focus 時邊框變 MP.blue 需要自己追蹤。
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // UI-20: 兩欄(左欄290|逐字稿)→單直欄,視窗可拉窄到 400。
            // 順序=Eric 指定:控制區 → 即時逐字稿(彈性主體) → 可收折列表。
            VStack(alignment: .leading, spacing: MP.spM) {
                controlSection
                // UI-21 v4: 逐字稿/最近錄音之間加可拖曳分隔(Eric 2026-07-11 指定)——
                // 比例由使用者拉,不再硬寫死列表高度。列表收折時鎖住下格高度,
                // 分隔線拖不動(等同以前的固定 header)。
                VSplitView {
                    transcriptSection
                        .frame(minHeight: 140, maxHeight: .infinity)
                    recordingsSection
                        .frame(minHeight: uiState.listExpanded ? 88 : 30,
                               maxHeight: uiState.listExpanded ? .infinity : 30)
                }
            }
            .padding(MP.spL)
            adBar
        }
        .overlay(alignment: .bottomTrailing) {
            ParrotMascot(size: 58, isRecording: controller.state == .recording)
                .offset(x: -8, y: 4).allowsHitTesting(false)
        }
        // UI-20: 最小尺寸統一由 MyParrotApp 的 frame 管(單一真相),這裡不再
        // 自帶——雙重約束取大者曾讓本層的值被 App 層舊 720 蓋掉。
        // UI-21: 移除 macOS 工具列——迷你/設定兩鈕改放 statusCard 首列右側(內容區,
        // 保證顯示、靠右、320pt 窄視窗不會被收進「»」)。原生標題列置中顯示視窗名。
        .sheet(isPresented: $uiState.showSettings) { SettingsView(controller: controller, updates: updates) }
        .task { await controller.requestPermissions() }
    }

    /// 錄音控制區(單欄最上):狀態卡+警告/權限橫幅+控制列,內容原封不動。
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: MP.spM) {
            statusCard
            if let warn = controller.deviceChangeWarning {
                HStack(spacing: MP.spS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warn).font(MPFont.caption).foregroundStyle(.orange).lineSpacing(3)
                    Spacer()
                    Button { controller.deviceChangeWarning = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .mpBanner(color: .orange)
            }
            if !controller.micPermission || !controller.speechPermission {
                permissionNotice
            }
            // UPD:非阻斷更新提示——僅 idle 時顯示(錄音/暫停中不打擾,開會場景)。
            if case .updateAvailable(let ver, let url) = updates.status,
               controller.state == .idle, !updateBannerDismissed {
                HStack(spacing: MP.spS) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(MP.blue)
                    Text(L("有新版本") + " v\(ver)").font(MPFont.caption)
                    Spacer()
                    Button(L("前往下載")) { NSWorkspace.shared.open(url) }.controlSize(.small)
                    Button(L("略過此版")) { updates.skip() }.controlSize(.small)
                    Button { updateBannerDismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .mpBanner(color: MP.blue)
            }
            ControlBar(controller: controller)
        }
    }

    /// 首列左半:狀態點 + 狀態字 + 計時器。
    private var statusLead: some View {
        HStack(spacing: MP.spS) {
            Circle().fill(controller.state == .recording ? MP.recRed : Color.secondary)
                .frame(width: 9, height: 9)
                // UI-22: 錄音中呼吸(opacity 0.5↔1.0);非錄音靜止(固定不透明)。
                .opacity(controller.state == .recording ? (recDotBreathe ? 1.0 : 0.5) : 1.0)
                .onAppear { updateRecDotBreathing() }
                .onChange(of: controller.state) { _, _ in updateRecDotBreathing() }
            Text(L(stateLabel)).font(MPFont.label)
                .foregroundStyle(controller.state == .recording ? MP.recRed : .secondary)
            Text(MP.clock(controller.elapsed))
                .font(MPFont.display)
                .lineLimit(1).fixedSize()   // UI-22: 320pt 首列擠時計時器絕不折行
        }
    }

    /// 首列右半:模式切換鈕 + 設定鈕,各自「icon + ⌘ 膠囊」框在同一顆常駐邊框內。
    private var headerButtons: some View {
        HStack(spacing: MP.spS) {
            // UI-21: 模式/設定鈕(自 macOS 工具列搬來)——放這張卡首列右側,靠右、
            // 窄視窗不收合。
            // UI-25: 迷你模式鈕改成三態模式切換鈕——icon 依目前模式變、內嵌
            // ⌘1 膠囊,點擊＝與按 ⌘1 相同的 cycle() 動作(不是直接跳迷你)。
            Button { windowMode.cycle() } label: {
                HStack(spacing: 3) {
                    // UI-22: 14pt 是圖示視覺尺寸(非文字級距),刻意不收進 MPFont。
                    Image(systemName: windowMode.mode.icon).font(.system(size: 14))
                    ShortcutBadge(symbol: "⌘1")
                }
            }
            .buttonStyle(.bordered)
            .mpShortcut("1")
            .help("\(L("切換模式")):\(L("標準視窗")) → \(L("窄版視窗")) → \(L("迷你控制列")) ⌘1")
            .accessibilityLabel(L("切換模式"))
            Button { uiState.showSettings = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gearshape").font(.system(size: 14))
                    ShortcutBadge(symbol: "⌘,")
                }
            }
            .buttonStyle(.bordered)
            .help("\(L("設定")) ⌘,")
            .accessibilityLabel(L("設定"))
        }
        .fixedSize()   // 膠囊絕不被擠成「⁝」(2026-08-23 窄版截圖)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            // UI-24 修正(Eric 2026-08-23 15:06 截圖):模式/設定兩鈕原用 .accessoryBar
            // (hover 才浮邊框)→ 圖示與 ⌘ 膠囊看起來沒框在一起;改 .bordered 常駐
            // 邊框,齒輪也嵌 ⌘, 膠囊(推翻 v3「齒輪只用 tooltip」)。窄版 320pt 一列
            // 放不下(計時器 88pt+兩顆含膠囊鈕 ~120pt)→ ViewThatFits 退成兩列:
            // 第二列兩鈕靠右,膠囊照印、不縮不裁。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MP.spS) {
                    statusLead
                    Spacer(minLength: MP.spXS)
                    headerButtons
                }
                VStack(alignment: .leading, spacing: MP.spXS) {
                    HStack(spacing: MP.spS) { statusLead; Spacer(minLength: 0) }
                    HStack(spacing: MP.spS) { Spacer(minLength: 0); headerButtons }
                }
            }
            LevelBar(label: L("對方"), value: controller.otherLevel, color: MP.coral,
                     recording: controller.state == .recording, hasSignal: controller.sysHasSignal)
            LevelBar(label: L("你"), value: controller.youLevel, color: MP.blue,
                     recording: controller.state == .recording, hasSignal: controller.micHasSignal)
            micPicker
            // UI-22: .roundedBorder(系統樣式)換成 .plain+自訂底,對齊卡片本身的
            // cornerRadius+stroke 語言;focus 時邊框亮 MP.blue。
            TextField(L("會議名稱"), text: $controller.currentTitle)
                .textFieldStyle(.plain)
                .font(MPFont.label)
                .focused($titleFieldFocused)
                .padding(.horizontal, MP.spS).padding(.vertical, MP.spXS)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(titleFieldFocused ? MP.blue : Color.clear, lineWidth: 1))
        }
        .padding(MP.spM)
        // UI-22 Phase B: 三層材質最厚重的一層——.ultraThinMaterial+頂部 2pt accent bar
        // (待錄 MP.blue/錄音 MP.recRed),用 overlay(top) 疊上再一起 clipShape,讓
        // accent bar 左右上角跟卡片圓角切齊,不外露方角。去 stroke,改陰影立體感。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(controller.state == .recording ? MP.recRed : MP.blue)
                .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    // UI-22: 錄音中啟動呼吸(repeatForever);非錄音時停掉並歸零(靜止實心)。
    private func updateRecDotBreathing() {
        guard controller.state == .recording else { recDotBreathe = false; return }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            recDotBreathe = true
        }
    }

    // 主畫面快速麥克風選擇器:一眼看到當下收音裝置、隨時可切(待機 + 錄音中都行,
    // 錄音中走熱切換不斷檔)。這是「本次臨時」選擇 → switchMic 不寫 UserDefaults;
    // 重開以設定裡的為主。藍牙標 ⚠️、iPhone 標 (iPhone)。
    private var micPicker: some View {
        HStack(spacing: MP.spS) {
            Image(systemName: "mic.fill").font(MPFont.caption).foregroundStyle(MP.blue)
            Picker("", selection: Binding(
                get: { controller.selectedInputDevice },
                set: { if let d = $0 { controller.switchMic(to: d) } })) {
                ForEach(controller.availableInputDevices) { dev in
                    Text(micLabel(dev)).tag(Optional(dev))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(MPFont.caption)
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: MP.spS) {
            Image(systemName: "lock.shield").foregroundStyle(MP.blue)
            Text(L("需要麥克風 / 語音辨識 / 系統音訊權限")).font(MPFont.caption).foregroundStyle(.secondary).lineSpacing(3)
            Spacer()
            Button(L("授權")) { Task { await controller.requestPermissions() } }.font(MPFont.caption)
        }
        .mpBanner(color: MP.blue)
    }

    /// UI-20: 最近錄音(單欄最下),標題列可收折省空間。
    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            // UI-22 Phase B: VSplitView 分隔把手視覺提示——純裝飾,不攔截點擊,
            // 不影響 VSplitView 拖曳行為(拖曳仍由系統分隔線本身處理)。
            Capsule().fill(Color.primary.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
            HStack {
                // v3 定稿:「最近錄音 ⌘K」整顆是可點 chip,膠囊在同一個 Button 邊框內。
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { uiState.listExpanded.toggle() }
                } label: {
                    HStack(spacing: MP.spXS) {
                        Image(systemName: "chevron.right")
                            .font(MPFont.caption.weight(.semibold))
                            .rotationEffect(.degrees(uiState.listExpanded ? 90 : 0))
                        Text(L("最近錄音")).font(MPFont.label)
                        ShortcutBadge(symbol: "⌘K")
                    }.foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .mpShortcut("k")
                .help("\(L(uiState.listExpanded ? "收折最近錄音" : "展開最近錄音")) ⌘K")
                .accessibilityLabel(L(uiState.listExpanded ? "收折最近錄音" : "展開最近錄音"))
                Spacer()
                // 「在 Finder 打開」chip 同款——膠囊在同一顆按鈕邊框內。
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.recordingsDir])
                } label: {
                    HStack(spacing: MP.spXS) {
                        Label(L("在 Finder 打開"), systemImage: "folder").font(MPFont.caption)
                        ShortcutBadge(symbol: "⌘O")
                    }
                }
                .buttonStyle(.borderless)
                .mpShortcut("o")
                .help("\(L("在 Finder 打開")) ⌘O")
                .accessibilityLabel(L("在 Finder 打開"))
            }
            // UI-17: 列表自己捲動、封頂高度,視窗縮放自由(單欄後封頂 300→200 再省空間)。
            if uiState.listExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: MP.spS) {
                        // 2026-08-24 Eric:列表 10 → 20 筆(更早的照舊用「在 Finder 打開」)。
                        ForEach(controller.recordings.prefix(20)) { rec in
                            RecordingRow(rec: rec, controller: controller)
                        }
                        if controller.recordings.isEmpty {
                            Text(L("尚無錄音")).font(MPFont.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                // UI-21 v4: 高度交給 VSplitView 分隔(使用者拖曳決定),不再硬封頂。
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            HStack {
                Text(L("即時逐字稿")).font(MPFont.label).foregroundStyle(.secondary)
                Spacer()
                transcriptRangeControl
            }
            // UI-17/20: 玻璃工具列淨空已搬到 statusCard 首列(單欄後這裡不在頂部)。
            if let err = controller.lastError {
                HStack(spacing: MP.spS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(MPFont.caption).foregroundStyle(.red).lineLimit(3).lineSpacing(3)
                    Spacer()
                    Button { controller.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .mpBanner(color: .red)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: MP.spM) {
                        // UI-33(Eric 2026-08-24):「轉逐字稿中/轉檔中」狀態改顯示在
                        // 錄音列表對應列上(訊息跟著主體),不再放這裡。
                        ForEach(visibleTranscript) { line in
                            TranscriptBubble(line: line)
                        }
                        if visibleTranscript.isEmpty && !controller.isTranscribing {
                            Text(L("開始錄音後,逐字稿會即時顯示在這裡;或對任一錄音檔按「轉逐字稿」。"))
                                .font(MPFont.label).foregroundStyle(.tertiary).lineSpacing(3).padding(.top, MP.spXS)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")   // UI-18 錨點
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(MP.spM)
                }
                .frame(minHeight: 80, maxHeight: .infinity)   // UI-21 v4: 下限交給外層 pane(140)管
                // UI-17: 泡泡原本沒被裁切,捲動時會溢出圓角框(macOS 26 還會
                // 透進工具列區)。
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // UI-22 Phase B: 三層材質中間層——保留極淡 fill 當底色,去 stroke
                // (跟 statusCard 的材質厚重感拉開主從)。
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                // UI-18: 會議進行中逐字稿自動跟到最新(新行、或 volatile 行更新都跟)。
                .onChange(of: controller.liveTranscript.count) { _, _ in autoScroll(proxy) }
                .onChange(of: controller.liveTranscript.last?.text) { _, _ in autoScroll(proxy) }
            }
            Label(L("分軌讓「誰說的」自動標好(對方左／你右)"), systemImage: "info.circle")
                .font(MPFont.caption).foregroundStyle(.tertiary)
        }
    }

    /// 「3 分鐘 | 完整 | ⌘L」分段控制。v3 定稿:⌘L 膠囊要在同一個邊框內、用
    /// 分隔線與選項隔開、不可點——原生 `.pickerStyle(.segmented)` 塞不進第三個
    /// 不可互動的偽分段,改手刻兩顆分段鈕+Divider+ShortcutBadge,外層共用一個
    /// 邊框(兩家二審「折衷」處置,見 plan.md v3 決策表)。
    private var transcriptRangeControl: some View {
        HStack(spacing: 2) {
            transcriptRangeSegment(L("3 分鐘"), selected: !uiState.fullTranscript) { uiState.fullTranscript = false }
            transcriptRangeSegment(L("完整"), selected: uiState.fullTranscript) { uiState.fullTranscript = true }
            Divider().frame(height: 14)
            ShortcutBadge(symbol: "⌘L").padding(.leading, 2)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(MP.line, lineWidth: 0.5))
        // ⌘L 的實際鍵盤處理走 AppCommands 的選單命令(容器本身不是 Button,掛
        // .keyboardShortcut 沒有動作可綁,故不重複掛);這裡只給 tooltip。個別
        // 分段鈕(3 分鐘/完整)保留各自的預設 accessibilityLabel,不用
        // .accessibilityElement(children: .combine) 合併——那樣 VoiceOver 會
        // 失去個別分段的可選取性,只有膠囊本身該被隱藏(ShortcutBadge 已內建
        // accessibilityHidden)。
        .help("\(L("逐字稿 3 分鐘／完整")) ⌘L")
    }

    private func transcriptRangeSegment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(MPFont.caption).fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, MP.spS).padding(.vertical, 3)
                .frame(minWidth: 50)
                .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 5))
                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        // 二審 Finding 5(a11y):手刻分段鈕取代原生 .pickerStyle(.segmented)後,
        // VoiceOver 不再自動念出「已選取」——原生分段控制的語意。個別按鈕仍
        // 各自可選取(決策 8 已說明為何不合併成單一 accessibilityElement),這裡
        // 只補回「已選取」的 trait。
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // UI-18: follow the newest line while recording. Not gated on "near bottom"
    // (macOS scroll-offset tracking isn't worth the complexity yet) — the 3-minute
    // window keeps the list short, and pausing auto-follow = switch to「完整」.
    private func autoScroll(_ proxy: ScrollViewProxy) {
        guard controller.state == .recording else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    // 「最近 3 分鐘」錨定最後一行時間(非牆鐘)→ 錄音中/結束後/舊檔轉稿語意
    // 一致,不再有 state gate(BUG-20:結束後 gate 讓切換形同虛設)。
    private var visibleTranscript: [TranscriptLine] {
        TranscriptWindow.visible(controller.liveTranscript, full: uiState.fullTranscript)
    }

    // UI-19: 廣告欄位現階段放大叔的 LinkedIn(Eric 2026-07-02 指定)。
    // UI-21: 上下兩行(Eric 2026-07-11 PDF 批註)——窄視窗時舊橫排把連結擠成多行直欄
    //       (macOS 26 的 Link 不繼承環境 lineLimit,559eea9 的截斷保護實測失效)。
    //       第 1 行 ViewThatFits:放得下顯全文,放不下顯短版;永不折行。
    // UI-22: build stamp 移去 SettingsView 底部(item 9),adBar 只剩 🦜+連結一行,
    //       VStack 兩行結構不再需要。
    private var adBar: some View {
        HStack(alignment: .center, spacing: MP.spS) {
            // UI-33(Eric 2026-08-24 06:06):🦜 emoji → 吉祥物迷你版;06:32 改用大頭圖
            // (全身縮 16pt 糊成一團,大頭才辨識得出);缺檔回落 idle 幀→emoji。
            if let head = ParrotMascot.headIcon ?? ParrotMascot.pngFrames?.idle {
                Image(nsImage: head).resizable().interpolation(.high)
                    .scaledToFit().frame(width: 16, height: 16)
            } else {
                Text("🦜").font(MPFont.caption)
            }
            ViewThatFits(in: .horizontal) {
                adLink("大叔的筆 — uncleric.com")
                adLink("大叔的筆")
            }
            Spacer(minLength: 0)
            // 2026-08-23 Eric:build no 回到 footer(官網連結變短後放得下);窄版自動縮成短 hash、再不夠就省略。
            // UI-33b(Eric 2026-08-24 06:33):build no 改為連到 GitHub repo(取代原本的可選取複製)。
            ViewThatFits(in: .horizontal) {
                buildLink(buildStamp)
                buildLink(buildStamp.split(separator: " ").last.map(String.init) ?? "")
                Text("")
            }
            .font(MPFont.caption).lineLimit(1)
        }
        .padding(.horizontal, MP.spL).padding(.vertical, MP.spS)
        .padding(.trailing, 58 + 8)  // = mascot 58 + inset 8
        .background(.bar)
        .overlay(Rectangle().fill(MP.line).frame(height: 1), alignment: .top)
    }

    // UI-21: Link 的 label 明確包 Text 並直接掛 lineLimit(環境傳遞在 macOS 26 對
    //       Link 失效);兩個寬度版本共用,URL 單一真相。
    // 2026-08-17: LinkedIn → 官網(Eric:不再幫 LinkedIn 導流)。
    private func adLink(_ label: String) -> some View {
        Link(destination: URL(string: "https://www.uncleric.com/")!) {
            // UI-33:底線+↗,一眼看得出可以按(Eric 2026-08-24 06:06:「不那麼直覺
            // 知道可以按」)。
            Text("\(label) ↗").font(MPFont.caption).underline().lineLimit(1)
        }
        // UI-33c(Eric 2026-08-24 08:52):SwiftUI Link 在 macOS 不自動給手型,補 pointerStyle。
        .pointerStyle(.link)
    }

    /// UI-33b:footer build no → GitHub repo;維持 tertiary 低調,hover 出 tooltip。
    private func buildLink(_ label: String) -> some View {
        Link(destination: URL(string: "https://github.com/tingyulu/MyParrot")!) {
            Text(label).font(MPFont.caption).foregroundStyle(.tertiary)
        }
        .pointerStyle(.link)   // UI-33c:同上,hover 手型
        .help(L("在 GitHub 上打開 MyParrot"))
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: return "待錄音"
        case .recording: return "錄音中"
        case .paused: return "已暫停"
        case .finished: return "結束後"
        }
    }
}

struct LevelBar: View {
    let label: String
    let value: Float
    let color: Color
    var recording: Bool = false
    var hasSignal: Bool = false
    // UI-22 Phase C: 20 段 Capsule 陣列取代單條連續 bar,更有「專業電平表」感——
    // 亮段數 = 段位映射(非連續寬度),錄音中亮段加發光,段數變化時彈簧動畫。
    private static let segmentCount = 20
    // 2026-08-23(Eric 拍板 3):改真 dB 刻度 −60…−12 dBFS(MeterScale,三處電平表同刻度);
    // 線性下一般語音只亮 3/20 像沒收到音。低電平至少亮 1 段的 UI-22 語意保留在 MeterScale。
    private var litSegments: Int { MeterScale.segments(value, of: Self.segmentCount) }
    var body: some View {
        HStack(spacing: MP.spS) {
            Text(label).font(MPFont.caption.weight(.medium)).foregroundStyle(color).frame(width: 34, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<Self.segmentCount, id: \.self) { i in
                    Capsule()
                        .fill(i < litSegments
                              ? AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.7)],
                                                              startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.08)))
                        // UI-22 主 session 補修:發光只給亮段(原本套整條,灰暗段也泛色暈顯髒)。
                        .shadow(color: (recording && i < litSegments) ? color.opacity(0.5) : .clear, radius: 3)
                }
            }
            .frame(height: 7)
            .animation(.spring(duration: 0.25), value: litSegments)
            if recording {
                HStack(spacing: MP.spXS) {
                    Image(systemName: hasSignal ? "checkmark.circle.fill" : "circle.dotted")
                        .font(MPFont.caption)
                        .foregroundStyle(hasSignal ? Color.green : .orange)
                    Text(L(hasSignal ? "收音中" : "等待訊號"))
                        .font(MPFont.caption).foregroundStyle(hasSignal ? Color.green : .orange)
                }.frame(width: 56, alignment: .leading)
            }
        }
    }
}

struct TranscriptBubble: View {
    let line: TranscriptLine
    var body: some View {
        VStack(alignment: line.isYou ? .trailing : .leading, spacing: MP.spXS) {
            Text("\(L(line.isYou ? "你" : "對方")) · \(time)")
                .font(MPFont.caption.weight(.medium))
                .foregroundStyle(line.isYou ? MP.blue : MP.coral)
            Text(line.text.isEmpty ? "…" : line.text)
                .font(MPFont.body)
                .padding(.horizontal, MP.spM).padding(.vertical, MP.spS)
                .background((line.isYou ? MP.blue : MP.coral).opacity(line.isFinal ? 0.16 : 0.08))
                // UI-22 Phase C: volatile(非 final)虛線描邊區分「還在辨識中」,
                // final 維持實線——比原本只靠 opacity 微調更一眼可辨。
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                    (line.isYou ? MP.blue : MP.coral).opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: line.isFinal ? [] : [4, 3])))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: line.isYou ? .trailing : .leading)
    }
    private var time: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: line.time)
    }
}

struct RecordingRow: View {
    let rec: Recording
    let controller: RecordingController
    // UI-22 Phase B: 三層材質最輕的一層——無底色,hover 才浮出淡底;不加逐項描邊,
    // 行與行之間靠卡片間距(MP.spS)分隔,不加 hairline。
    @State private var isHovering = false
    /// 這一列是不是「使用中的播放器」(播放中/暫停中/播完待收回都算)。
    private var isActive: Bool { controller.playingURL == rec.url }
    // 副標：轉稿/轉檔狀態就地顯示(UI-33) / [時長 · ]雙聲道[ · 已轉稿]
    private var subtitle: String {
        if controller.transcribingID == rec.id { return L("轉逐字稿中…") }
        if rec.isConverting {
            return controller.transcribeQueued.contains(rec.id)
                ? L("轉檔中,完成後自動轉逐字稿…") : L("處理中…")
        }
        if controller.transcribeQueued.contains(rec.id) { return L("已排隊,稍後轉逐字稿…") }
        let kind = L(rec.hasTranscript ? "雙聲道 · 已轉稿" : "雙聲道")
        // UI-28b 降級:波形算失敗/逾時 → 副標尾端標示,不報錯框。
        let tail = (isActive && controller.waveformFailed.contains(rec.url)) ? " · \(L("波形不可用"))" : ""
        guard rec.duration > 0 else { return kind + tail }
        return "\(Self.durationLabel(rec.duration)) · \(kind)\(tail)"
    }
    private static func durationLabel(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    // UI-27(Eric 拍板 B):主鈕 ▶⇄❚❚,播完變 ↻;顏色:播放中紅、其餘藍。
    private var playIcon: String {
        guard isActive else { return "play.fill" }
        switch controller.playbackPhase {
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        case .ended: return "arrow.counterclockwise"
        }
    }
    private var playLabel: String {
        guard isActive else { return L("播放") }
        switch controller.playbackPhase {
        case .playing: return L("暫停")
        case .paused: return L("繼續")
        case .ended: return L("重播")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MP.spXS) {
            HStack(spacing: MP.spS) {
                Button { controller.togglePlay(rec) } label: {
                    Image(systemName: playIcon)
                        .font(MPFont.body)
                        .foregroundStyle(isActive && controller.playbackPhase == .playing ? MP.recRed : MP.blue)
                        .frame(width: 16)
                }
                .buttonStyle(.accessoryBar)
                .help(playLabel)
                .accessibilityLabel("\(playLabel) \(rec.title)")
                // UI-22: 標題 13pt semibold / 副標 caption——主從不再只靠顏色分辨。
                VStack(alignment: .leading, spacing: MP.spXS) {
                    Text(rec.title).font(MPFont.body.weight(.semibold)).lineLimit(1)
                    // UI-28 方案 4:播放中副標右側放兩條短型即時電平;窄版放不下時
                    // ViewThatFits 退成副標/電平兩行。
                    if isActive {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: MP.spM) {
                                Text(subtitle).font(MPFont.caption).foregroundStyle(.secondary).fixedSize()
                                Spacer(minLength: MP.spS)
                                miniMeters
                            }
                            VStack(alignment: .leading, spacing: MP.spXS) {
                                Text(subtitle).font(MPFont.caption).foregroundStyle(.secondary)
                                miniMeters
                            }
                        }
                    } else {
                        Text(subtitle)
                            .font(MPFont.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                // UI-30(Eric 2026-08-23):已轉稿 → 打開 .txt;未轉稿 → 轉稿。重轉走右鍵。
                // UI-33:這一列轉稿中 → 圖示換轉圈(狀態跟著主體)。
                Button {
                    if rec.hasTranscript { NSWorkspace.shared.open(rec.transcriptURL) }
                    else { controller.transcribe(rec) }
                } label: {
                    if controller.transcribingID == rec.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "doc.text")
                    }
                }
                    .buttonStyle(.accessoryBar).foregroundStyle(rec.hasTranscript ? Color.green : .primary)
                    // gemini 二審:排隊中也禁(重按雖冪等,但按了沒反應=假入口)。
                    .disabled(controller.transcribingID == rec.id || controller.transcribeQueued.contains(rec.id))
                    .help(L(rec.hasTranscript ? "打開逐字稿" : "轉逐字稿"))
                    .accessibilityLabel(L(rec.hasTranscript ? "打開逐字稿" : "轉逐字稿"))
            }
            // UI-27:播放中的列多一行進度列(點擊/拖曳 seek)。
            if isActive {
                PlaybackProgressBar(time: controller.playbackTime,
                                    duration: controller.playbackDuration,
                                    onSeek: { controller.seek(to: $0) },
                                    onRestart: { controller.restartPlayback() },
                                    waveform: controller.waveforms[rec.url])
                    .padding(.leading, 16 + MP.spS)   // 對齊標題(主鈕寬 16 + 間距)
                    .padding(.trailing, MP.spXS)
                    // UI-28b:列展開就開始背景算波形(冪等;算好前先畫純軌道)。
                    .onAppear { controller.requestWaveform(for: rec.url) }
            }
        }
        .padding(MP.spS)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isActive ? MP.blue.opacity(0.08) : (isHovering ? Color.primary.opacity(0.06) : Color.clear)))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        // UI-27:「從頭播放」放右鍵選單(主要入口)+「錄音」選單;停止播放一併給。
        .contextMenu {
            if isActive {
                Button(L("從頭播放")) { controller.restartPlayback() }
                Button(L("停止播放")) { controller.stopPlayback() }
            } else {
                Button(L("播放")) { controller.togglePlay(rec) }
            }
            Divider()
            if rec.hasTranscript {
                Button(L("打開逐字稿")) { NSWorkspace.shared.open(rec.transcriptURL) }
                Button(L("重新轉逐字稿")) { controller.transcribe(rec) }
                    .disabled(controller.isTranscribing)
            } else {
                Button(L("轉逐字稿")) { controller.transcribe(rec) }
                    .disabled(controller.isTranscribing)
            }
        }
    }

    private var miniMeters: some View {
        HStack(spacing: MP.spM) {
            MiniLevelMeter(label: L("對方"), value: controller.playbackOtherLevel, color: MP.coral)
            MiniLevelMeter(label: L("你"), value: controller.playbackYouLevel, color: MP.blue)
        }
        .fixedSize()
    }
}

struct ControlBar: View {
    let controller: RecordingController
    var body: some View {
        HStack(spacing: MP.spS) {
            switch controller.state {
            case .idle:
                redButton("開始錄音", "record.circle", "⌘R", "r") { controller.startRecording() }
            case .recording:
                plainButton("暫停", "pause", "⌘P", "p") { controller.pause() }
                redButton("結束", "stop", "⌘E", "e") { controller.stop() }
            case .paused:
                plainButton("繼續", "play", "⌘P", "p") { controller.resume() }
                redButton("結束", "stop", "⌘E", "e") { controller.stop() }
                // ⌘N 定稿只在 finished 狀態啟用(見 AppCommands)——這裡維持既有
                // 「暫停中也能按新錄音」的直接點擊行為,但不掛膠囊/快捷鍵,避免
                // 本地 .keyboardShortcut 在 paused 狀態搶先觸發、繞過選單的
                // finished-only 判斷式。
                plainButton("新錄音", "plus") { controller.newRecording() }
            case .finished:
                if let last = controller.recordings.first {
                    plainButton("轉逐字稿", "doc.text", "⌘T", "t") { controller.transcribe(last) }
                }
                plainButton("新錄音", "plus", "⌘N", "n") { controller.newRecording() }
            }
        }
    }

    private func redButton(_ key: String, _ icon: String, _ badge: String? = nil,
                            _ shortcutKey: Character? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: MP.spXS) {
                Label(L(key), systemImage: icon).font(MPFont.body.weight(.medium))
                if let badge { ShortcutBadge(symbol: badge, onAccent: true) }
            }
        }
        // UI-24 修正:失焦不變灰(見 MPButtonStyle.swift)。
        .buttonStyle(.mpProminent)
        .mpShortcut(shortcutKey)
        .help(badge.map { "\(L(key)) \($0)" } ?? L(key))
        .accessibilityLabel(L(key))
    }
    private func plainButton(_ key: String, _ icon: String, _ badge: String? = nil,
                              _ shortcutKey: Character? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: MP.spXS) {
                Label(L(key), systemImage: icon).font(MPFont.body)
                if let badge { ShortcutBadge(symbol: badge) }
            }
        }
        .buttonStyle(.bordered)
        .mpShortcut(shortcutKey)
        .help(badge.map { "\(L(key)) \($0)" } ?? L(key))
        .accessibilityLabel(L(key))
    }
}
