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

    var body: some View {
        VStack(spacing: 0) {
            // #2438 M4:單直欄(控制區 → 逐字稿 → 可收折列表,VSplitView)→ 面板工作區:
            // 控制欄(遙控器＋橫幅＋檔案面板)＋逐字稿／筆記／會議記錄直欄,見 WorkspaceView。
            WorkspaceView(controller: controller, updates: updates, uiState: uiState, windowMode: windowMode)
                .padding(WorkspaceView.outerPadding)
            adBar
        }
        // #2438 淺色底(mockup --win):卡片是白的,底要比卡片暗一階;深色同理。
        .background(MP.floor)
        // UI-20: 最小尺寸統一由 MyParrotApp 的 frame 管(單一真相),這裡不再
        // 自帶——雙重約束取大者曾讓本層的值被 App 層舊 720 蓋掉。
        // UI-21: 移除 macOS 工具列——迷你/設定兩鈕改放遙控器狀態藥丸右側(內容區,
        // 保證顯示、靠右、窄視窗不會被收進「»」)。原生標題列置中顯示視窗名。
        .sheet(isPresented: $uiState.showSettings) { SettingsView(controller: controller, updates: updates, uiState: uiState) }
        .task {
            #if DEBUG
            // #949 驗證用(只有 DEBUG 建置):`-debugSkipPermissionRequest YES` ⇒ 啟動不請麥克風／語音辨識權限。
            // 從 harness 直接執行 .build/debug/MyParrot 時 TCC 歸因到宿主 app,一請就跳框或 SIGABRT;
            // 示範夾驗證不錄音,用不到權限。release 連這段都不編。
            if UserDefaults.standard.bool(forKey: "debugSkipPermissionRequest") { return }
            #endif
            await controller.requestPermissions()
        }
        // UI-57(Eric 2026-10-20 A1):首次啟動一次性說明框——兩個模型功能預設關、在哪開。主視窗出現 1.5 秒後再跳,
        // 免得跟啟動時的系統權限框撞在一起;迷你模式沒有 RootView,下次標準模式再跳。
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled, ModelHint.shouldShow() { uiState.showModelHint = true }
        }
        .alert(L("逐字稿校正與會議記錄要先在設定開啟"), isPresented: $uiState.showModelHint) {
            Button(L("打開設定")) { uiState.modelHintOpenSettings() }
            Button(L("稍後"), role: .cancel) { uiState.modelHintLater() }
        } message: {
            Text(L("這兩個功能預設關閉,沒選模型後端時不會出現。到「設定 → 模型」各自選後端(目前支援 Claude CLI,在本機執行)。隨時可以再關掉。"))
        }
        // #2438 M5:筆記／會議記錄跟著錄音狀態與選中列走(plan §3.5 文件切換)。
        .onAppear { syncNotesInitial() }
        .onChange(of: controller.state) { old, new in notesStateChanged(from: old, to: new) }
        // #2483 C(TRX-04):重轉完成 ⇒ 會議記錄帳目重設(只對顯示中那場)。
        .onChange(of: controller.transcriptVersion) { _, _ in
            guard let n = uiState.notes, let s = n.stem, let src = controller.transcriptSource,
                  SidecarSet.stem(of: src.url) == s else { return }
            n.minutes.rebase()
        }
        .onChange(of: uiState.selectedRecording) { _, id in selectRecording(id) }
    }

    // MARK: #2438 M5 文件切換

    private func syncNotesInitial() {
        guard let n = uiState.notes else { return }
        switch controller.state {
        case .idle: n.showDraft()
        case .finished: if let r = controller.recordings.first { n.show(recording: r.url) } else { n.showDraft() }
        case .recording, .paused: attachCurrent(n)
        }
    }

    private func attachCurrent(_ n: NotesSession) {
        if let url = controller.currentRecordingURL {
            n.recordingStarted(url: url, title: controller.currentTitle)
            n.minutes.startAuto(transcript: { controller.liveTranscript }, notes: { n.store.text },
                                language: { controller.language })
        } else {
            // 錄音檔 URL 在狀態翻成 recording 的同一輪可能還沒指定,晚半秒再試一次。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if controller.state == .recording || controller.state == .paused, n.lockedStem == nil { attachCurrent(n) }
            }
        }
    }

    private func notesStateChanged(from old: RecordingState, to new: RecordingState) {
        guard let n = uiState.notes else { return }
        switch new {
        case .recording where old == .idle || old == .finished:
            attachCurrent(n)
        case .finished:
            n.recordingStopped()
            n.minutes.endAuto()
            // E 定案:自動模式下結束時也自動跑最後一次(MIN-04:沒新東西就不花錢)。
            if n.minutes.autoEnabled, n.minutes.isAvailable { Task { await n.updateMinutesNow(controller: controller, manual: false) } }
        case .idle:
            n.minutes.endAuto()
            n.showDraft()
        default:
            break
        }
    }

    /// 點選列:筆記與會議記錄切到那場;逐字稿也讀那場的 .srt(錄音中不切,筆記鎖在進行中那場)。
    private func selectRecording(_ id: UUID?) {
        guard let id, let rec = controller.recordings.first(where: { $0.id == id }), let n = uiState.notes else { return }
        guard controller.state == .idle || controller.state == .finished else { return }
        n.show(recording: rec.url)
        if rec.hasTranscript { _ = controller.loadTranscript(for: rec) }
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

}
