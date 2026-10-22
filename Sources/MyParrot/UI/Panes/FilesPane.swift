import SwiftUI
import AppKit
import MyParrotCore

/// #2438 M4:左欄下半的檔案面板＝原 `RootView.recordingsSection`＋`RecordingRow` 原樣搬來(播放列、波形、
/// 迷你電平、右鍵選單全保留)。展開時吃左欄剩餘高度、收折時只剩標題列(⌘K)。M5 再加搜尋、sidecar 標記、
/// 選中切欄、重新命名、移到垃圾桶。
struct FilesPane: View {
    let controller: RecordingController
    @Bindable var uiState: AppUIState
    @State private var loc = Localizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
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
            // UI-17: 列表自己捲動;M4 起高度＝左欄剩餘高度(不再有 VSplitView 分隔)。
            if uiState.listExpanded {
                // UI-52:搜尋標題(大小寫不分);有字時最多列 50 筆,沒字照舊 20 筆。
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(MPFont.caption).foregroundStyle(.tertiary)
                    TextField(L("搜尋標題"), text: $uiState.filesQuery).textFieldStyle(.plain).font(MPFont.caption)
                    if !uiState.filesQuery.isEmpty {
                        Button { uiState.filesQuery = "" } label: { Image(systemName: "xmark.circle.fill").font(MPFont.caption) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                ScrollView {
                    VStack(alignment: .leading, spacing: MP.spS) {
                        // 2026-08-24 Eric:列表 10 → 20 筆(更早的照舊用「在 Finder 打開」)。
                        ForEach(filteredRecordings) { rec in
                            RecordingRow(rec: rec, controller: controller, uiState: uiState)
                        }
                        if !uiState.filesQuery.isEmpty && filteredRecordings.isEmpty {
                            Text(L("沒有符合的錄音")).font(MPFont.caption).foregroundStyle(.tertiary)
                        }
                        if controller.recordings.isEmpty {
                            Text(L("尚無錄音")).font(MPFont.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(MP.spS)
        .frame(maxHeight: uiState.listExpanded ? .infinity : nil, alignment: .top)
        .modifier(PaneCardStyle())
    }

    private var filteredRecordings: [Recording] {
        let q = uiState.filesQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(controller.recordings.prefix(20)) }
        return Array(controller.recordings.filter { $0.title.localizedCaseInsensitiveContains(q) }.prefix(50))
    }
}

struct RecordingRow: View {
    let rec: Recording
    let controller: RecordingController
    /// #2438 M5:點列 ⇒ 選中(三欄切到那場;UI-52);右鍵改名／垃圾桶要筆記 session。
    var uiState: AppUIState? = nil
    private var isSelected: Bool { uiState?.selectedRecording == rec.id }
    /// 副標＋sidecar 標記(逐字稿／筆記／記錄,有檔才亮)。
    private var subtitleLine: some View {
        HStack(spacing: 5) {
            Text(subtitle)
            SidecarChips(stem: SidecarSet.stem(of: rec.url))
        }
    }
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
        // #949 REC-32:頂層殘留的 .caf(舊版 writer 的活檔或中斷檔)只讀不動,24 小時後右鍵才有「修復」。
        if rec.needsManualRepair { return L("未完成錄音，右鍵修復") }
        // QUIT-13(#1697):上次「轉稿中退出」被中斷的那筆——只標記,不自動重轉。
        if controller.wasInterrupted(rec) {
            let tail = (isActive && controller.waveformFailed.contains(rec.url)) ? " · \(L("波形不可用"))" : ""
            let head = rec.duration > 0 ? "\(Self.durationLabel(rec.duration)) · " : ""
            return "\(head)\(L("雙聲道")) · \(L("上次未完成"))\(tail)"
        }
        // #2483 E(TRX-07):等閒置再高精度重轉的那筆。
        if controller.pendingHighAccuracy.contains(rec.id) {
            let head = rec.duration > 0 ? "\(Self.durationLabel(rec.duration)) · " : ""
            return "\(head)\(L(rec.hasTranscript ? "雙聲道 · 已轉稿" : "雙聲道")) · \(L("待高精度重轉"))"
        }
        // #949:收割端從中斷錄音復原的那一筆(檔名「-已修復」固定繁中,副標依介面語言標出來)。
        let repaired = rec.title.hasSuffix(Recording.repairedSuffix) ? " · \(L("已修復"))" : ""
        let kind = L(rec.hasTranscript ? "雙聲道 · 已轉稿" : "雙聲道") + repaired
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
                                subtitleLine.font(MPFont.caption).foregroundStyle(.secondary).fixedSize()
                                Spacer(minLength: MP.spS)
                                miniMeters
                            }
                            VStack(alignment: .leading, spacing: MP.spXS) {
                                subtitleLine.font(MPFont.caption).foregroundStyle(.secondary)
                                miniMeters
                            }
                        }
                    } else {
                        subtitleLine
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
            isActive ? MP.blue.opacity(0.08) : (isSelected ? MP.coral.opacity(0.10) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? MP.coral.opacity(0.45) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { uiState?.selectedRecording = rec.id }
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
            // #949:頂層殘檔超過 24 小時才給「修復」(轉成 m4a);未滿 24 小時可能是舊版 writer 還在寫,不給。
            if controller.canRepair(rec) {
                Button(L("修復")) { controller.repair(rec) }
            }
            Divider()
            if rec.hasTranscript {
                Button(L("打開逐字稿")) { NSWorkspace.shared.open(rec.transcriptURL) }
                // #2417:把這筆的 .srt 讀回畫面再送校正(開關關閉時不出現)。
                if controller.correctionBackend != .off, rec.hasTranscript {
                    Button(L("檢查逐字稿")) {
                        if controller.loadTranscript(for: rec) { Task { await controller.checkTranscript() } }
                    }
                }
                Button(L("重新轉逐字稿")) { controller.transcribe(rec) }
                    .disabled(controller.isTranscribing)
            } else {
                Button(L("轉逐字稿")) { controller.transcribe(rec) }
                    .disabled(controller.isTranscribing)
            }
            // #2438 M5:筆記／會議記錄／改名／垃圾桶(UI-52/53/54)。鎖住(錄音中、轉檔中、轉稿中、排隊中)⇒ disabled。
            let stem = SidecarSet.stem(of: rec.url)
            let notesURL = SidecarSet.url(stem: stem, ext: "notes.md")
            let minutesURL = SidecarSet.url(stem: stem, ext: "minutes.md")
            let hasNotes = FileManager.default.fileExists(atPath: notesURL.path)
            let hasMinutes = FileManager.default.fileExists(atPath: minutesURL.path)
            if hasNotes || hasMinutes {
                Divider()
                if hasNotes { Button(L("打開筆記")) { NSWorkspace.shared.open(notesURL) } }
                if hasMinutes { Button(L("打開會議記錄")) { NSWorkspace.shared.open(minutesURL) } }
            }
            Divider()
            let locked = controller.isFileActionLocked(rec)
            if controller.pendingHighAccuracy.contains(rec.id) {
                Button(L("現在重轉")) { controller.transcribeNow(rec) }   // #2483 E
            }
            Button(L("重新命名…")) { FileActions.rename(rec, controller: controller, session: uiState?.notes) }
                .disabled(locked)
            Button(L("移到垃圾桶…")) { FileActions.trash(rec, controller: controller, session: uiState?.notes) }
                .disabled(locked)
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
