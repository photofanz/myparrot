import SwiftUI
import MyParrotCore

/// #2438 T3／MDL-03:模型後端的「選擇流程」。設定頁 picker 與 DebugControl `model request` 走同一條路。
/// - 選到出機後端(`isLocal == false`)而且這個後端還沒同意過 ⇒ 先掛起(`pending`),等隱私確認框。
/// - 「開啟」⇒ 記住 `privacyAccepted.<後端>`(一個後端只問一次,兩個能力共用)再套用;「取消」⇒ 該能力退回 off。
/// - 套用一律走 `ModelBackendRegistry.select`;校正那列另外把 `controller.correctionBackend` 對齊
///   (它仍是 SwiftUI 觀察與「檢查逐字稿」入口的單一真相,didSet 也寫 `model.correction`)。
@MainActor
@Observable
final class ModelSelectionFlow {
    struct Pending: Identifiable, Equatable {
        let capability: ModelCapability
        let backendID: String
        var id: String { "\(capability.rawValue)>\(backendID)" }
    }

    /// 等使用者回答隱私確認框的那一筆;nil＝沒有在問。
    var pending: Pending?

    func request(_ backendID: String, for cap: ModelCapability, controller: RecordingController, ui: AppUIState) {
        if ModelBackendRegistry.needsPrivacyConfirmation(backendID) {
            pending = Pending(capability: cap, backendID: backendID)
        } else {
            pending = nil
            Self.apply(backendID, for: cap, controller: controller, ui: ui)
        }
    }

    func confirm(controller: RecordingController, ui: AppUIState) {
        guard let p = pending else { return }
        pending = nil
        ModelBackendRegistry.acceptPrivacy(p.backendID)
        Self.apply(p.backendID, for: p.capability, controller: controller, ui: ui)
    }

    func cancel(controller: RecordingController, ui: AppUIState) {
        guard let p = pending else { return }
        pending = nil
        Self.apply(ModelBackendRegistry.offID, for: p.capability, controller: controller, ui: ui)
    }

    /// 直接寫入(不問):設定頁「不用問」的情況與 DebugControl `model set` 共用。
    static func apply(_ backendID: String, for cap: ModelCapability, controller: RecordingController, ui: AppUIState?) {
        ModelBackendRegistry.select(backendID, for: cap)
        if cap == .translation { ui?.notes?.translation.refreshProvider() }   // #2612
        if cap == .correction {
            let resolved = CorrectionBackend(rawValue: ModelBackendRegistry.selected(for: .correction).id) ?? .off
            if controller.correctionBackend != resolved { controller.correctionBackend = resolved }
        }
        ui?.refreshMinutesEnabled()
    }

    /// 隱私說明跟後端走(T3 第 5 點),文案依能力。出機後端只有 Claude CLI;將來的雲端後端在這裡加自己的文案。
    static func privacyText(backendID: String, capability: ModelCapability) -> String {
        switch (backendID, capability) {
        case (ModelBackendRegistry.claudeCLI.id, .correction):
            return L("開啟後,按「檢查逐字稿」會把逐字稿文字交給這台電腦上的 Claude Code 送到 Anthropic,用你自己的訂閱額度;不送音訊、檔名與會議名稱。")
        case (ModelBackendRegistry.claudeCLI.id, .minutes):
            return L("開啟後,每次更新會議記錄都會把逐字稿與筆記全文交給這台電腦上的 Claude Code 送到 Anthropic,用你自己的訂閱額度;不送音訊與檔名。")
        // #2418 CDX-06:Codex 送出的內容與 Claude 一字不差,只有送達處與額度不同。
        case (ModelBackendRegistry.codexCLI.id, .correction):
            return L("開啟後,按「檢查逐字稿」會把逐字稿文字交給這台電腦上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 訂閱額度;不送音訊、檔名與會議名稱。")
        case (ModelBackendRegistry.codexCLI.id, .minutes):
            return L("開啟後,每次更新會議記錄都會把逐字稿與筆記全文交給這台電腦上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 訂閱額度;不送音訊與檔名。")
        // #2612 TRL-06
        case (ModelBackendRegistry.claudeCLI.id, .translation):
            return L("開啟後,每批會把自上次之後新定稿行的文字交給這台電腦上的 Claude Code 送到 Anthropic,用你自己的訂閱額度;不送講者、時間、音訊與檔名。")
        case (ModelBackendRegistry.codexCLI.id, .translation):
            return L("開啟後,每批會把自上次之後新定稿行的文字交給這台電腦上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 訂閱額度;不送講者、時間、音訊與檔名。")
        default:
            return L("開啟後,資料會送出這台電腦,交給所選的後端處理。")
        }
    }

    /// B3(MIN-07):確認框以**後端**為單位,一次列出這個後端每個能力各送什麼;同一後端只問一次。
    static func privacyPromptTitle(backendID: String) -> String {
        switch backendID {
        case ModelBackendRegistry.claudeCLI.id: return L("開啟 Claude CLI(本機)")
        case ModelBackendRegistry.codexCLI.id: return L("開啟 Codex CLI(本機)")     // #2418 CDX-06
        default: return L("要開啟這個後端嗎?")
        }
    }

    /// 第一句依後端(送到哪、花誰的額度);「各功能送出的內容」兩段與「一律不送」句所有 CLI 後端共用(CDX-06)。
    static func privacyPromptText(backendID: String) -> String {
        let lead: String
        switch backendID {
        case ModelBackendRegistry.claudeCLI.id:
            lead = L("這個後端會把文字交給這台電腦上的 Claude Code,再送到 Anthropic,用你自己的訂閱額度。各功能送出的內容:")
        case ModelBackendRegistry.codexCLI.id:
            lead = L("這個後端會把文字交給這台電腦上的 Codex CLI,再送到 OpenAI,用你自己的 ChatGPT 訂閱額度。各功能送出的內容:")
        default:
            return L("開啟後,資料會送出這台電腦,交給所選的後端處理。")
        }
        // 四句分開翻(check-translations 的兩個掃描器對 \n 轉義處理不一致,key 不放換行)。
        return [lead,
                L("• 逐字稿校正:按「檢查逐字稿」時,該批逐字稿的段號與文字。"),
                L("• 會議記錄:每次更新時,上一版會議記錄、自上次之後的逐字稿(含「你／對方」標籤與時間)、筆記全文(含你寫的標題)。"),
                L("• 逐字稿翻譯:每批送出自上次之後新定稿行的文字與目標語言。"),
                L("一律不送:音訊、檔名、路徑、錄音日期與裝置名稱。")].joined(separator: "\n")
    }
}

/// MDL-03／MIN-07 隱私確認框:掛在設定頁根節點(sheet 開著就一定在),以後端為單位列出每個能力送什麼(B3)。
/// 設定頁被關掉(Esc 監聽會整張關)時還在問 ⇒ 當作取消,不留懸著的選擇。
struct ModelPrivacyPrompt: ViewModifier {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState

    func body(content: Content) -> some View {
        let flow = uiState.modelFlow
        content
            .alert(ModelSelectionFlow.privacyPromptTitle(backendID: flow.pending?.backendID ?? ""),
                   isPresented: Binding(get: { flow.pending != nil }, set: { _ in }),
                   presenting: flow.pending) { _ in
                Button(L("開啟")) { flow.confirm(controller: controller, ui: uiState) }
                Button(L("取消"), role: .cancel) { flow.cancel(controller: controller, ui: uiState) }
            } message: { p in
                Text(ModelSelectionFlow.privacyPromptText(backendID: p.backendID))
            }
            .onDisappear { if flow.pending != nil { flow.cancel(controller: controller, ui: uiState) } }
    }
}

/// #2438 T3 第 3 點:設定頁單一「模型」區段(取代 #2417 的「逐字稿校正」區段)。
/// 每個能力一列 picker(Phase 1:校正、會議記錄;翻譯列 Phase 3 才顯示),選項＝登錄表 `backends(for:)`
/// (release 不含假供應商);預設全部關閉。有能力選了 Claude CLI ⇒ 顯示 CLI 狀態與共用的模型檔位欄。
/// 會議記錄後端 ≠ off 才出現「會議記錄」區(自動更新開關＋每 N 分鐘 2～15,E 定案)。
struct ModelSettingsSection: View {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState
    @State private var cliState: CLIState = .unknown
    /// #2418 CDX-03:Codex CLI 狀態(找不到／未登入／就緒),與 Claude 的分開顯示。
    @State private var codexState: CLIState = .unknown
    /// #2438 Phase 3a:Apple 本機模型可用性(設定頁開啟時再探一次)。
    @State private var afm = AppleFMAvailability.shared
    /// 只為了讓畫面跟著偏好變(DebugControl `model set`／其他寫入);值仍經登錄表解析(`selected(for:)`)。
    @AppStorage("model.minutes") private var minutesRaw = ModelBackendRegistry.offID
    @AppStorage("model.translation") private var translationRaw = ModelBackendRegistry.offID   // #2612
    /// 會議記錄 session 不存在時的後備(讀寫同兩把偏好鍵,預設與 `MinutesController` 一致)。
    @AppStorage("minutes.auto") private var autoPref = true
    @AppStorage("minutes.cadence") private var cadencePref = 5

    enum CLIState { case unknown, missing, notLoggedIn, ready }

    /// 本建置可選、但還不能真的用的選項的佔位(將來本地小模型的位置);disabled,選不到。
    private static let localPlaceholderTag = "__localPlaceholder"

    private var flow: ModelSelectionFlow { uiState.modelFlow }

    var body: some View {
        Section {
            capabilityRow(.correction, title: L("逐字稿校正"))
            capabilityRow(.minutes, title: L("會議記錄"))
            capabilityRow(.translation, title: L("逐字稿翻譯"))   // #2612 TRL-01
            if selectedID(.translation) != ModelBackendRegistry.offID, let tr = uiState.notes?.translation {
                translationExtras(tr)
            }
            if usesClaudeCLI {
                HStack(spacing: MP.spS) {
                    Image(systemName: cliState == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(cliState == .ready ? .green : .orange)
                    Text(statusText).font(MPFont.caption).foregroundStyle(cliState == .ready ? Color.secondary : Color.orange)
                }
                // grouped Form 的原生排法:標籤在左、欄位在右,提示字當 placeholder。
                TextField(text: $controller.correctionModel, prompt: Text(L("選填,留空跟 CLI 預設走"))) {
                    Text(L("Claude CLI 模型檔位（校正與會議記錄共用）"))
                }
                .font(MPFont.caption)
            }
            // #2418 CDX-03／08:有能力選了 Codex CLI ⇒ 顯示它的狀態與自己的檔位欄(與 Claude 的欄位分開,兩家檔名不同)。
            if usesCodexCLI {
                HStack(spacing: MP.spS) {
                    Image(systemName: codexState == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(codexState == .ready ? .green : .orange)
                    Text(codexStatusText).font(MPFont.caption).foregroundStyle(codexState == .ready ? Color.secondary : Color.orange)
                }
                TextField(text: $controller.codexModel, prompt: Text(L("選填,留空跟 CLI 預設走"))) {
                    Text(L("Codex CLI 模型檔位（校正與會議記錄共用）"))
                }
                .font(MPFont.caption)
            }
            // AFM-01/02:Apple 本機模型狀態列——有選它、或這台列得出來但目前不可用,都講清楚。
            if afm.isPlatformSupported, usesAppleFM || !afm.isAvailable {
                HStack(spacing: MP.spS) {
                    Image(systemName: afm.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(afm.isAvailable ? .green : .orange)
                    Text(afm.message ?? L("Apple 本機模型可用")).font(MPFont.caption)
                        .foregroundStyle(afm.isAvailable ? Color.secondary : Color.orange).lineSpacing(3)
                }
            }
        } header: { Text(L("模型")) }
        footer: {
            Text(L("每個功能各自選後端;預設全部關閉,沒選後端的功能不會出現。") +
                 (afm.isPlatformSupported ? "\n" + L("Apple 本機模型:資料不出機") : "") +
                 (usesCodexCLI ? "\n" + L("Codex CLI:文字會送到 OpenAI") : "") +
                 (usesAppleTranslation ? "\n" + L("Apple 翻譯:資料不出機") : ""))
                .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
        }
        .onAppear { refreshCLIState(); refreshCodexState(); afm.refresh(); uiState.notes?.translation.reprobeAvailability() }
        .onChange(of: usesClaudeCLI) { _, _ in refreshCLIState() }
        .onChange(of: usesCodexCLI) { _, _ in refreshCodexState() }
        // 隱私確認框掛在設定頁根節點(`ModelPrivacyPrompt`),不掛在這個 Section:grouped Form 的列可能延遲載入,
        // 捲出畫面時 Section 的 alert／onDisappear 不可靠。

        if selectedID(.minutes) != ModelBackendRegistry.offID {
            Section {
                Toggle(L("自動更新"), isOn: autoBinding)
                Stepper(value: cadenceBinding, in: MinutesController.cadenceRange) {
                    Text(Lf("每 %@ 分鐘更新一次", ["\(cadenceBinding.wrappedValue)"]))
                        .monospacedDigit()
                }
                .disabled(!autoBinding.wrappedValue)
            } header: { Text(L("會議記錄")) }
        }
    }

    // MARK: 能力列

    @ViewBuilder
    private func capabilityRow(_ cap: ModelCapability, title: String) -> some View {
        let current = selectedID(cap)
        Picker(title, selection: Binding(
            get: { current },
            set: { newID in
                guard newID != Self.localPlaceholderTag, newID != current else { return }
                flow.request(newID, for: cap, controller: controller, ui: uiState)
            })) {
            ForEach(options(cap)) { b in
                // AFM-02:這台跑不起來的 Apple 本機模型列出但停用(原因在下面那行)。
                Text(L(b.label)).tag(b.id).disabled(b.id == ModelBackendRegistry.appleFM.id && !afm.isAvailable)
            }
            Text(L("本地模型(尚未提供)")).tag(Self.localPlaceholderTag).disabled(true)
        }
        if let info = options(cap).first(where: { $0.id == current }), !info.isLocal {
            Text(ModelSelectionFlow.privacyText(backendID: current, capability: cap))
                .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
        }
        // Phase 2:後端選了但這台跑不起來(找不到 claude)⇒ 講原因,不假裝能用。
        if cap == .minutes, let n = uiState.notes, let reason = n.minutes.unavailableReason {
            Text(reason).font(MPFont.caption).foregroundStyle(.orange)
        }
    }

    /// 選單選項:登錄表 `backends(for:)`;會議記錄只列這個建置真的有實作的後端(A2 裁示,見 `MinutesController.implementedBackendIDs`)。
    private func options(_ cap: ModelCapability) -> [ModelBackendInfo] {
        let all = ModelBackendRegistry.backends(for: cap)
        return cap == .minutes ? all.filter { MinutesController.implementedBackendIDs.contains($0.id) } : all
    }

    /// 目前選的後端 id(已經過登錄表解析:不認得／本建置不提供 ⇒ off)。
    private func selectedID(_ cap: ModelCapability) -> String {
        switch cap {
        case .correction:
            return controller.correctionBackend.rawValue
        case .minutes:
            _ = minutesRaw   // 建立對偏好的觀察
            return ModelBackendRegistry.selected(for: .minutes).id
        case .translation:
            _ = translationRaw   // 建立對偏好的觀察
            return ModelBackendRegistry.selected(for: .translation).id
        }
    }

    private var usesAppleTranslation: Bool { selectedID(.translation) == ModelBackendRegistry.appleTranslation.id }

    // MARK: #2612 TRL-01／03 翻譯附加列:目標語言、CLI 送出節奏(＋Codex 30 秒警語)、Apple 語言包狀態

    @ViewBuilder
    private func translationExtras(_ tr: TranslationController) -> some View {
        Picker(L("目標語言"), selection: Binding(get: { tr.target }, set: { tr.target = $0 })) {
            ForEach(TranslationTarget.allCases, id: \.self) { Text(L($0.label)).tag($0) }
        }
        if tr.isCLI {
            Picker(L("送出節奏"), selection: Binding(get: { tr.cadenceSeconds }, set: { tr.cadenceSeconds = $0 })) {
                ForEach(TranslationPlan.cadenceOptions, id: \.self) { Text(Self.cadenceLabel($0)).tag($0) }
            }
            if tr.backendID == ModelBackendRegistry.codexCLI.id, tr.cadenceSeconds <= TranslationPlan.codexWarnCadence {
                let est = TranslationPlan.estimatedTokensPerHour(cadenceSec: tr.cadenceSeconds, basePerCall: 13_500) / 10_000
                Text(Lf("每小時約 %@ 萬 tokens(Codex 每批固定背 13.5k)", ["\(est)"])).font(MPFont.caption).foregroundStyle(.orange)
            }
            if let reason = tr.unavailableReason {
                Text(reason).font(MPFont.caption).foregroundStyle(.orange)
            }
        }
        if tr.isApple {
            HStack(spacing: MP.spS) {
                switch tr.effectiveAvailability {
                case .installed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("語言包已安裝")).font(MPFont.caption).foregroundStyle(.secondary)
                case .supported:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("需下載語言包")).font(MPFont.caption).foregroundStyle(.orange)
                    Button(L("下載語言包")) { tr.wantsLanguageDownload = true }.controlSize(.small)
                case .unsupported:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(tr.sourceSameAsTarget ? L("辨識語言與目標語言相同,沒有東西可翻") : L("此語言組合不支援")).font(MPFont.caption).foregroundStyle(.orange)
                case .unknown, .notApplicable:
                    ProgressView().controlSize(.small)
                    Text(L("檢查語言包中…")).font(MPFont.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func cadenceLabel(_ sec: Int) -> String {
        switch sec {
        case 30: return L("30 秒")
        case 60: return L("1 分鐘")
        case 120: return L("2 分鐘")
        default: return L("5 分鐘")
        }
    }

    private var usesClaudeCLI: Bool {
        [ModelCapability.correction, .minutes].contains { selectedID($0) == ModelBackendRegistry.claudeCLI.id }
    }

    private var usesCodexCLI: Bool {
        [ModelCapability.correction, .minutes].contains { selectedID($0) == ModelBackendRegistry.codexCLI.id }
    }

    private var usesAppleFM: Bool {
        [ModelCapability.correction, .minutes].contains { selectedID($0) == ModelBackendRegistry.appleFM.id }
    }

    // MARK: 會議記錄區(E 定案:自動更新可開關、間隔 2～15 分、預設 5)

    private var autoBinding: Binding<Bool> {
        Binding(get: { uiState.notes?.minutes.autoEnabled ?? autoPref },
                set: { on in
                    guard let n = uiState.notes else { autoPref = on; return }
                    n.minutes.autoEnabled = on
                    // 錄音中切換要當場生效:關＝停排程;開＝照錄音開始時同一組來源重排(startAuto 會先停舊的)。
                    if !on {
                        n.minutes.stopAuto()
                    } else if controller.state == .recording || controller.state == .paused, n.lockedStem != nil {
                        n.minutes.startAuto(transcript: { controller.liveTranscript }, notes: { n.store.text },
                                            language: { controller.language })
                    }
                })
    }

    private var cadenceBinding: Binding<Int> {
        let range = MinutesController.cadenceRange
        return Binding(get: { uiState.notes?.minutes.cadenceMinutes ?? min(range.upperBound, max(range.lowerBound, cadencePref)) },
                       set: { v in
                           let c = min(range.upperBound, max(range.lowerBound, v))
                           if let n = uiState.notes { n.minutes.cadenceMinutes = c } else { cadencePref = c }
                       })
    }

    // MARK: Claude CLI 狀態(沿用 #2417)

    private var statusText: String {
        switch cliState {
        case .unknown: return L("檢查中…")
        case .missing: return L("找不到 claude 指令,請先安裝 Claude Code")
        case .notLoggedIn: return L("Claude Code 尚未登入,請在終端機執行 claude /login")
        case .ready: return L("已找到 Claude Code,已登入")
        }
    }

    private func refreshCLIState() {
        guard usesClaudeCLI else { return }
        cliState = .unknown
        Task {
            guard let exe = ClaudeCLIProvider.locate() else { cliState = .missing; return }
            cliState = await ClaudeCLIProvider.isLoggedIn(executable: exe) ? .ready : .notLoggedIn
        }
    }

    // MARK: Codex CLI 狀態(#2418 CDX-03)

    private var codexStatusText: String {
        switch codexState {
        case .unknown: return L("檢查中…")
        case .missing: return L("找不到 codex 指令,請先安裝 Codex CLI")
        case .notLoggedIn: return L("Codex CLI 尚未登入,請在終端機執行 codex login")
        case .ready: return L("已找到 Codex CLI,已登入")
        }
    }

    private func refreshCodexState() {
        guard usesCodexCLI else { return }
        codexState = .unknown
        Task {
            guard let exe = CodexCLIProvider.locate() else { codexState = .missing; return }
            codexState = await CodexCLIProvider.isLoggedIn(executable: exe) ? .ready : .notLoggedIn
        }
    }
}
