import SwiftUI
import AppKit
import MyParrotCore

/// #2438 M4:逐字稿直欄的內容＝原 `RootView.transcriptSection` 原樣搬來(檢查逐字稿、建議列表、錯誤橫幅、
/// 泡泡捲動區、底部提示)。欄標題(圖示＋名稱＋⋮⋮／◀ ▶／×)由 `PaneContainer` 畫;原本的「即時逐字稿」
/// 小標拿掉(欄標題已經是「逐字稿」),「3 分鐘／完整 ⌘L」移到欄標題列右側(`TranscriptRangeControl`)。
/// M5 再升級(跟到最新膠囊、引用到筆記)。
struct TranscriptPane: View {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState
    @State private var loc = Localizer.shared
    /// UI-51:使用者往上捲(距底 > 40pt)就暫停自動跟隨,出「↓ 跟到最新」膠囊;按膠囊或捲回底部恢復。
    @State private var followPaused = false
    @State private var lastContentHeight: CGFloat = 0
    /// UI-60:選中建議對應的逐字稿行(泡泡加粗藍框);跟著 `uiState.focusedSuggestionID` 走,清單清空就消。
    @State private var highlightedLineID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            // #2417:只在校正開關開著、且畫面上這份稿有來源錄音時出現(CORR-01)。
            if controller.correctionBackend != .off, controller.transcriptSource != nil, !controller.liveTranscript.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        Task { await controller.checkTranscript() }
                    } label: {
                        if controller.isCheckingTranscript { ProgressView().controlSize(.small) }
                        Text(controller.isCheckingTranscript ? L("檢查中…") : L("檢查逐字稿"))
                    }
                    .controlSize(.small).disabled(controller.isCheckingTranscript)
                }
            }
            if !controller.correctionSuggestions.isEmpty {
                CorrectionSuggestionList(controller: controller, selectedID: uiState.focusedSuggestionID,
                                         onSelect: { uiState.focusedSuggestionID = $0.id })
            }
            // #2612 TRL-09:重轉後譯文失效,提示重翻。
            if let tr = uiState.notes?.translation, tr.isEnabled, tr.stale {
                HStack(spacing: MP.spS) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text(L("逐字稿已更新,譯文需重翻")).font(MPFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("翻譯整份")) { uiState.notes?.translateWholeNow(controller: controller) }.controlSize(.small).disabled(!tr.isAvailable)
                }
                .mpBanner(color: .orange)
            }
            if let tr = uiState.notes?.translation, let err = tr.lastError, tr.isEnabled {
                HStack(spacing: MP.spS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(MPFont.caption).foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button { tr.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .mpBanner(color: .orange)
            }
            if let err = controller.lastError {
                HStack(spacing: MP.spS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(CoreMessageL10n.localize(err)).font(MPFont.caption).foregroundStyle(.red).lineLimit(3).lineSpacing(3)
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
                            TranscriptBubble(line: line, onQuote: uiState.notes == nil ? nil : { quote(line) },
                                             highlighted: line.id == highlightedLineID,
                                             translation: translationState(line), onRetry: { uiState.notes?.translation.retry(line.id) })
                                .id(line.id)   // UI-60:scrollTo 的錨
                        }
                        if visibleTranscript.isEmpty && !controller.isTranscribing {
                            // #949 REC-35:CLI 在錄的那一場沒有 GUI 的即時逐字稿,講清楚,不讓人以為壞了。
                            Text(controller.externalRecording != nil
                                 ? L("此場由 CLI 錄製，沒有即時逐字稿")
                                 : L("開始錄音後,逐字稿會即時顯示在這裡;或對任一錄音檔按「轉逐字稿」。"))
                                .font(MPFont.label).foregroundStyle(.tertiary).lineSpacing(3).padding(.top, MP.spXS)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")   // UI-18 錨點
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(MP.spM)
                }
                .frame(minHeight: 80, maxHeight: .infinity)
                // UI-17: 泡泡捲動時不可溢出圓角框(欄容器另有一層裁切)。
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // UI-18: 會議進行中逐字稿自動跟到最新(新行、或 volatile 行更新都跟)。
                .onChange(of: controller.liveTranscript.count) { _, _ in autoScroll(proxy) }
                .onChange(of: controller.liveTranscript.last?.text) { _, _ in autoScroll(proxy) }
                // 只有「內容高度沒變、位移變了」才算使用者在捲(新行長出來那一下不算)。
                .onScrollGeometryChange(for: ScrollProbe.self) { g in
                    ScrollProbe(contentHeight: g.contentSize.height,
                                distanceFromBottom: g.contentSize.height - (g.contentOffset.y + g.containerSize.height),
                                offset: g.contentOffset.y, containerHeight: g.containerSize.height)
                } action: { _, p in
                    uiState.transcriptScroll = [p.offset, p.contentHeight, p.containerHeight]   // DebugControl `state.transcriptScroll`(UI-60 驗證用)
                    defer { lastContentHeight = p.contentHeight }
                    guard controller.state == .recording, p.contentHeight == lastContentHeight else { return }
                    followPaused = p.distanceFromBottom > 40
                }
                .overlay(alignment: .bottom) {
                    if followPaused, controller.state == .recording {
                        Button {
                            followPaused = false
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                        } label: {
                            Label(L("跟到最新"), systemImage: "arrow.down").font(MPFont.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(.thinMaterial))
                                .overlay(Capsule().stroke(MP.line, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, MP.spS)
                        .help(L("跟到最新"))
                    }
                }
                // UI-60:選中建議 ⇒ 捲到該段。掛在逐字稿 ScrollView 自己的 reader 裡(第一版把 reader 包在整欄外面,
                // 建議清單的 ScrollView 也在裡面,scrollTo 找不到 id、真機沒捲)。
                .onChange(of: uiState.focusedSuggestionID) { _, id in focus(id, proxy) }
                .onChange(of: uiState.transcriptScrollRequest) { _, r in debugScroll(r, proxy) }   // DEBUG 對照組
            }
            Label(L("分軌讓「誰說的」自動標好(對方左／你右)"), systemImage: "info.circle")
                .font(MPFont.caption).foregroundStyle(.tertiary)
            // #2623 TOK-04:這場的模型用量(有帳才顯示)。
            if let line = uiState.notes?.tokenSummaryLine {
                Label(line, systemImage: "number.circle").font(MPFont.caption).foregroundStyle(.tertiary)
            }
            // #2612 TRL-03:Apple 翻譯的 session 只能從 view 拿;隱形 host 掛在這裡。
            if let tr = uiState.notes?.translation {
                AppleTranslationHost(translation: tr, source: controller.language.resolved().language)
            }
        }
        // #2612:載入舊稿／轉稿完成 ⇒ 把既有譯文檔對回畫面上的行(不排佇列;錄音中由 controller 的 loop 排)。
        .onChange(of: controller.liveTranscript.count) { _, _ in
            guard controller.state == .idle || controller.state == .finished else { return }
            uiState.notes?.translation.sync(transcript: controller.liveTranscript, language: controller.language, enqueue: false)
        }
        .onChange(of: controller.transcriptSource?.id) { _, _ in
            uiState.notes?.translation.sync(transcript: controller.liveTranscript, language: controller.language, enqueue: false)
        }
        .onChange(of: controller.correctionSuggestions.isEmpty) { _, empty in
            if empty { uiState.focusedSuggestionID = nil; highlightedLineID = nil }
        }
    }

    /// UI-60:選中建議 ⇒ 逐字稿捲到該段並高亮;該段不在 3 分鐘視窗 ⇒ 先切「完整」、等一輪 layout 再捲。
    private func focus(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id, let item = controller.correctionSuggestions.first(where: { $0.id == id }),
              let idx = CorrectionFocus.lineIndex(segment: item.suggestion.segment, count: controller.liveTranscript.count) else {
            highlightedLineID = nil
            return
        }
        let line = controller.liveTranscript[idx]
        highlightedLineID = line.id
        let needsFull = CorrectionFocus.needsFullTranscript(lineID: line.id, visible: visibleTranscript)
        #if DEBUG
        print("UI-60 focus id=\(id) idx=\(idx) full=\(uiState.fullTranscript) needsFull=\(needsFull)")
        #endif
        if needsFull, !uiState.fullTranscript {
            uiState.fullTranscript = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                scrollNow(to: line.id, proxy)
            }
        } else {
            scrollNow(to: line.id, proxy)
        }
    }

    /// 只走 reader 的 scrollTo、不包動畫(第一版 reader 包整欄＋withAnimation 在真機零偏移;改成 reader 只包逐字稿
    /// ScrollView、不包動畫後四個位置都捲到;🚫 不用 scrollPosition(id:) 綁定——它會在錄音中跟 UI-18「跟到最新」搶位置)。
    private func scrollNow(to id: UUID, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(id, anchor: .center)
    }

    /// DebugControl `transcript scroll bottom|<index>`:對照組,走 UI-18「跟到最新」同一個 scrollTo。
    private func debugScroll(_ request: String?, _ proxy: ScrollViewProxy) {
        guard let request else { return }
        let what = request.split(separator: "#").first.map(String.init) ?? ""
        #if DEBUG
        print("UI-60 debugScroll \(what) lines=\(controller.liveTranscript.count)")
        #endif
        if what == "bottom" { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
        else if let i = Int(what), i >= 0, i < controller.liveTranscript.count { proxy.scrollTo(controller.liveTranscript[i].id, anchor: .center) }
    }

    // UI-18: follow the newest line while recording. Not gated on "near bottom"
    // (macOS scroll-offset tracking isn't worth the complexity yet) — the 3-minute
    // window keeps the list short, and pausing auto-follow = switch to「完整」.
    private struct ScrollProbe: Equatable {
        var contentHeight: CGFloat
        var distanceFromBottom: CGFloat
        var offset: CGFloat
        var containerHeight: CGFloat
    }

    /// #2612 TRL-07:這一行的譯文狀態(顯示譯文關掉 ⇒ none)。
    private func translationState(_ line: TranscriptLine) -> TranslationController.LineState {
        guard let tr = uiState.notes?.translation, tr.isEnabled, tr.showTranslations else { return .none }
        return tr.lineState(for: line.id)
    }

    /// 泡泡 hover 的「引用到筆記」:`> 對方 h:mm:ss：…` 接在筆記文末,筆記欄沒開就開;有譯文就原文＋譯文兩行(TRL-07)。
    private func quote(_ line: TranscriptLine) {
        guard let n = uiState.notes else { return }
        let text = n.translation.translations[line.id].map { line.text + "\n" + $0 } ?? line.text
        n.appendQuote(speakerLabel: L(line.isYou ? "你" : "對方"), elapsed: line.start, text: text)
        if !uiState.panes.open.contains(.notes) { uiState.panes.toggle(.notes) }
    }

    private func autoScroll(_ proxy: ScrollViewProxy) {
        guard controller.state == .recording, !followPaused else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    // 「最近 3 分鐘」錨定最後一行時間(非牆鐘)→ 錄音中/結束後/舊檔轉稿語意
    // 一致,不再有 state gate(BUG-20:結束後 gate 讓切換形同虛設)。
    private var visibleTranscript: [TranscriptLine] {
        TranscriptWindow.visible(controller.liveTranscript, full: uiState.fullTranscript)
    }
}

/// 「3 分鐘 | 完整 | ⌘L」分段控制(原 `RootView.transcriptRangeControl`,M4 搬到逐字稿欄標題列)。
/// v3 定稿:⌘L 膠囊要在同一個邊框內、用分隔線與選項隔開、不可點——原生 `.pickerStyle(.segmented)`
/// 塞不進第三個不可互動的偽分段,改手刻兩顆分段鈕+Divider+ShortcutBadge,外層共用一個
/// 邊框(兩家二審「折衷」處置,見 plan.md v3 決策表)。
struct TranscriptRangeControl: View {
    @Bindable var uiState: AppUIState
    @State private var loc = Localizer.shared

    var body: some View {
        HStack(spacing: 2) {
            segment(L("3 分鐘"), selected: !uiState.fullTranscript) { uiState.fullTranscript = false }
            segment(L("完整"), selected: uiState.fullTranscript) { uiState.fullTranscript = true }
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

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
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
}

struct TranscriptBubble: View {
    let line: TranscriptLine
    /// #2438 M5:hover 出「引用到筆記」小鈕;nil＝不顯示(沒有筆記 session)。
    var onQuote: (() -> Void)? = nil
    /// UI-60:被校正建議選中的那一段 ⇒ 加粗藍框、底色加深。
    var highlighted = false
    /// #2612 TRL-07:譯文在同一泡泡原文下方(該側顏色較淡的小字);翻譯中「⋯」、失敗「未譯」可點重送。
    var translation: TranslationController.LineState = .none
    var onRetry: (() -> Void)? = nil
    @State private var hovering = false
    var body: some View {
        VStack(alignment: line.isYou ? .trailing : .leading, spacing: MP.spXS) {
            Text("\(L(line.isYou ? "你" : "對方")) · \(time)")
                .font(MPFont.caption.weight(.medium))
                .foregroundStyle(line.isYou ? MP.blue : MP.coral)
            Text(line.text.isEmpty ? "…" : line.text)
                .font(MPFont.body)
                .padding(.horizontal, MP.spM).padding(.vertical, MP.spS)
                .background((line.isYou ? MP.blue : MP.coral).opacity(highlighted ? 0.28 : (line.isFinal ? 0.16 : 0.08)))
                // UI-22 Phase C: volatile(非 final)虛線描邊區分「還在辨識中」,
                // final 維持實線——比原本只靠 opacity 微調更一眼可辨。
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                    highlighted ? MP.blue : (line.isYou ? MP.blue : MP.coral).opacity(0.3),
                    style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: line.isFinal ? [] : [4, 3])))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            switch translation {
            case .done(let t):
                Text(t).font(MPFont.caption).foregroundStyle((line.isYou ? MP.blue : MP.coral).opacity(0.85))
                    .padding(.horizontal, MP.spM).lineSpacing(2).textSelection(.enabled)
            case .pending:
                Text("⋯").font(MPFont.caption).foregroundStyle(.tertiary).padding(.horizontal, MP.spM)
            case .failed:
                Button { onRetry?() } label: { Text(L("未譯")).font(MPFont.caption).foregroundStyle(.orange) }
                    .buttonStyle(.plain).padding(.horizontal, MP.spM).help(L("重送這一行"))
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: line.isYou ? .trailing : .leading)
        .onHover { hovering = $0 }
        .overlay(alignment: line.isYou ? .topLeading : .topTrailing) {
            if hovering, let onQuote {
                Button(action: onQuote) {
                    Label(L("引用到筆記"), systemImage: "quote.opening").font(MPFont.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.thinMaterial))
                        .overlay(Capsule().stroke(MP.line, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(L("引用到筆記"))
            }
        }
    }
    private var time: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: line.time)
    }
}
