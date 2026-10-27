import Foundation
import Observation
import os
import MyParrotCore

/// #2612 TRL(#2438 T3 Phase 3):逐字稿翻譯的 App 層狀態機,照 `MinutesController` 形狀。
/// - 後端來自 `ModelBackendRegistry.selected(for: .translation)`:Apple 翻譯(本機、逐行即時;session 由 `AppleTranslationHost` 供)、
///   Claude CLI／Codex CLI(批次,節奏 `translation.cadence` 秒)、DEBUG 的 localFake;off ⇒ `isEnabled == false` ⇒ 沒有任何翻譯 UI。
/// - 只翻定稿行(`isFinal`);譯文住 `translations[lineID]`,落檔 `<stem>.<目標語言>.srt`(TRL-08),🚫 不動 `.srt`／`.txt`／筆記。
/// - 失敗的行進 `failed`(畫面標「未譯」可重送);連續 3 次失敗自動暫停(沿 MIN-05),手動「立即翻譯」恢復。
@MainActor
@Observable
final class TranslationController {
    static let showKey = "translation.show"

    /// Apple 翻譯的語言包狀態(TRL-03);CLI 後端＝`.notApplicable`。
    enum Availability: String { case unknown, installed, supported, unsupported, notApplicable }
    /// 每一行在畫面上的狀態(TRL-07)。
    enum LineState { case none, pending, failed, done(String) }

    private(set) var backendID: String = ModelBackendRegistry.offID
    var isEnabled: Bool { backendID != ModelBackendRegistry.offID }
    var isApple: Bool { backendID == ModelBackendRegistry.appleTranslation.id }
    var isCLI: Bool { backendID == ModelBackendRegistry.claudeCLI.id || backendID == ModelBackendRegistry.codexCLI.id }
    /// CLI 後端選了但這台跑不起來的原因(找不到 claude／codex);nil＝沒問題或後端關閉。
    private(set) var unavailableReason: String?
    private(set) var availability: Availability = .unknown
    /// 來源(辨識語言)與目標語言相同 ⇒ Apple 回 unsupported;設定頁要講清楚是這個原因,不是語言包。
    private(set) var sourceSameAsTarget = false
    /// DEBUG `translation availability force …` 覆寫;nil＝照真的。
    var forcedAvailability: Availability?
    var effectiveAvailability: Availability { forcedAvailability ?? availability }
    /// 每 +1 讓 `AppleTranslationHost` 重探一次(設定頁開啟、回前景)。
    private(set) var availabilityProbe = 0

    var target: TranslationTarget {
        didSet {
            defaults.set(target.rawValue, forKey: TranslationTarget.defaultsKey)
            if target != oldValue { targetChanged() }
        }
    }
    var cadenceSeconds: Int {
        didSet { defaults.set(cadenceSeconds, forKey: TranslationPlan.cadenceKey) }
    }
    var showTranslations: Bool {
        didSet { defaults.set(showTranslations, forKey: Self.showKey) }
    }

    private(set) var translations: [UUID: String] = [:]
    private(set) var failed: Set<UUID> = []
    private(set) var inFlight: Set<UUID> = []
    private(set) var pending: [TranscriptLine] = []
    private(set) var isTranslating = false
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    var lastError: String?
    private(set) var consecutiveFailures = 0
    private(set) var autoPaused = false
    /// TRX 重轉後逐字稿整份換掉 ⇒ 譯文清空、提示重翻(譯文檔保留舊版直到下一次翻譯覆寫)。
    private(set) var stale = false
    private(set) var stem: URL?
    private(set) var lastSentAt: Date?
    /// 「翻譯整份」進度;nil＝沒在跑。
    private(set) var wholeProgress: (done: Int, total: Int)?
    /// 設定頁「下載語言包」按下 ⇒ host 在 session 上呼叫 `prepareTranslation()`(系統框由使用者按)。
    var wantsLanguageDownload = false
    /// TRL-12 驗證用:送出過幾批(off 時必須維持 0)。
    private(set) var batchCount = 0

    @ObservationIgnored private var sourceLanguage: TranscriptionLanguage = .system
    @ObservationIgnored private var cliProvider: (any TranslationProvider)?
    @ObservationIgnored private var appleProvider: (any TranslationProvider)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var liveTranscript: (@MainActor () -> [TranscriptLine])?
    @ObservationIgnored private var liveLanguage: (@MainActor () -> TranscriptionLanguage)?
    /// 最近一次 sync 進來的整份逐字稿(寫譯文檔用)。
    @ObservationIgnored private var currentLines: [TranscriptLine] = []
    /// attach 時讀到的既有譯文檔,等第一次拿到逐字稿再對齊。
    @ObservationIgnored private var fileLines: [TranscriptLine]?
    /// 翻譯整份／結束錄音:一批接一批送到清空。
    @ObservationIgnored private var draining = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let log = Logger(subsystem: "tw.uncle.MyParrot", category: "translation")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        target = TranslationTarget.resolve(defaults.string(forKey: TranslationTarget.defaultsKey))
        let c = defaults.object(forKey: TranslationPlan.cadenceKey) == nil ? TranslationPlan.defaultCadence : defaults.integer(forKey: TranslationPlan.cadenceKey)
        cadenceSeconds = TranslationPlan.cadenceOptions.contains(c) ? c : TranslationPlan.defaultCadence
        showTranslations = defaults.object(forKey: Self.showKey) == nil ? true : defaults.bool(forKey: Self.showKey)
        refreshProvider()
    }

    // MARK: 後端

    private var provider: (any TranslationProvider)? { isApple ? appleProvider : cliProvider }

    /// 後端選了、而且這台現在真的能翻。
    var isAvailable: Bool {
        guard isEnabled else { return false }
        if isApple { return effectiveAvailability == .installed && appleProvider != nil }
        return cliProvider != nil
    }

    func refreshProvider() {
        let selected = ModelBackendRegistry.selected(for: .translation, defaults: defaults)
        backendID = selected.id
        unavailableReason = nil
        cliProvider = nil
        switch selected.id {
        case ModelBackendRegistry.offID:
            pending = []
            inFlight = []
            stopAuto()
        case ModelBackendRegistry.appleTranslation.id:
            break   // session 由 AppleTranslationHost 供;可用性由它探
        case ModelBackendRegistry.claudeCLI.id:
            if let exe = ClaudeCLIProvider.locate() {
                cliProvider = ClaudeCLITranslationProvider(executable: exe, model: defaults.string(forKey: MinutesController.cliModelKey), target: target)
            } else {
                unavailableReason = L("找不到 claude 指令,請先安裝 Claude Code")
            }
        case ModelBackendRegistry.codexCLI.id:
            if let exe = CodexCLIProvider.locate() {
                cliProvider = CodexCLITranslationProvider(executable: exe, model: defaults.string(forKey: MinutesController.codexModelKey), target: target)
            } else {
                unavailableReason = L("找不到 codex 指令,請先安裝 Codex CLI")
            }
        default:
            #if DEBUG
            if selected.id == "localFake" { cliProvider = LocalFakeTranslationProvider() }
            #endif
        }
        if !isApple { availability = .notApplicable }
        // 錄音中才把後端打開:loop 沒起來就補起來。
        if isEnabled, loop == nil, liveTranscript != nil { startLoop() }
    }

    func reprobeAvailability() { availabilityProbe += 1 }

    func setAvailability(_ a: Availability, sourceSameAsTarget same: Bool = false) { availability = a; sourceSameAsTarget = same }

    /// `AppleTranslationHost` 的 translationTask 閉包活著時提供 session;閉包結束(view 消失／設定變)就收回。
    func appleSessionReady(_ p: any TranslationProvider) { appleProvider = p }
    func appleSessionGone() { appleProvider = nil }

    /// Apple 路徑由 host 每 0.25 s 叫一次:有待翻就立刻送(cadence 0)。
    func applePump() {
        guard isApple else { return }
        flushIfDue(force: false)
    }

    private func targetChanged() {
        translations = [:]
        failed = []
        pending = []
        fileLines = nil
        stale = false
        if let s = stem, let text = try? String(contentsOf: SidecarSet.url(stem: s, ext: target.fileExtension), encoding: .utf8) {
            fileLines = SRT.parse(text)
            // 換目標語言時畫面上的稿還在:立刻把那個語言的既有譯文檔對回來,不等下一次 sync。
            if let f = fileLines, !currentLines.isEmpty {
                translations = TranslationSRT.align(original: currentLines, translated: f)
                fileLines = nil
            }
        }
        refreshProvider()
        reprobeAvailability()
    }

    // MARK: 附著

    func attach(stem newStem: URL?) {
        stopAuto()
        liveTranscript = nil
        liveLanguage = nil
        stem = newStem
        translations = [:]
        failed = []
        inFlight = []
        pending = []
        currentLines = []
        fileLines = nil
        lastError = nil
        consecutiveFailures = 0
        autoPaused = false
        stale = false
        wholeProgress = nil
        draining = false
        lastSentAt = nil
        guard let s = newStem else { return }
        if let text = try? String(contentsOf: SidecarSet.url(stem: s, ext: target.fileExtension), encoding: .utf8) {
            fileLines = SRT.parse(text)
        }
    }

    // MARK: 同步與佇列

    /// 畫面上這份逐字稿進來:對齊既有譯文檔;`enqueue` 才把新定稿行排進佇列(錄音中與翻譯整份);到節奏點就送。
    func sync(transcript: [TranscriptLine], language: TranscriptionLanguage, enqueue: Bool, force: Bool = false) {
        currentLines = transcript
        sourceLanguage = language
        if let f = fileLines, translations.isEmpty, !transcript.isEmpty {
            translations = TranslationSRT.align(original: transcript, translated: f)
            fileLines = nil
        }
        guard isEnabled else { return }
        if enqueue {
            let known = Set(pending.map(\.id)).union(inFlight).union(failed)
            for line in transcript where line.isFinal && !line.text.isEmpty && translations[line.id] == nil && !known.contains(line.id) {
                pending.append(line)
            }
        }
        flushIfDue(force: force)
    }

    func lineState(for id: UUID) -> LineState {
        if let t = translations[id] { return .done(t) }
        if failed.contains(id) { return .failed }
        if inFlight.contains(id) || pending.contains(where: { $0.id == id }) { return .pending }
        return .none
    }

    /// 立即翻譯(⌘⇧T、選單):有錄音中來源就先 sync 再強制送;否則送佇列裡的。
    func translateNow() {
        autoPaused = false
        if let t = liveTranscript, let l = liveLanguage {
            sync(transcript: t(), language: l(), enqueue: true, force: true)
        } else {
            flushIfDue(force: true)
        }
    }

    /// 重送一行(「未譯」可點)。
    func retry(_ id: UUID) {
        guard failed.contains(id), let line = currentLines.first(where: { $0.id == id }) else { return }
        failed.remove(id)
        pending.append(line)
        autoPaused = false
        flushIfDue(force: true)
    }

    func retryAllFailed() {
        let ids = failed
        failed = []
        for line in currentLines where ids.contains(line.id) { pending.append(line) }
        autoPaused = false
        flushIfDue(force: true)
    }

    /// 翻譯整份(舊錄音、或重轉後重翻):把還沒譯的定稿行全部排進去,一批接一批送到清空(TRL-09)。
    func translateWhole(lines: [TranscriptLine], language: TranscriptionLanguage) {
        currentLines = lines
        sourceLanguage = language
        stale = false
        let known = Set(pending.map(\.id)).union(inFlight)
        let todo = lines.filter { $0.isFinal && !$0.text.isEmpty && translations[$0.id] == nil && !known.contains($0.id) }
        failed.subtract(todo.map(\.id))
        pending.append(contentsOf: todo)
        guard !pending.isEmpty else { return }
        wholeProgress = (0, pending.count)
        draining = true
        autoPaused = false
        flushIfDue(force: true)
    }

    /// TRX-04 同款:高精度重轉把逐字稿整份換掉 ⇒ 譯文清空、提示重翻;檔案保留舊版直到下一次翻譯覆寫。
    func markStale() {
        guard isEnabled || !translations.isEmpty else { return }
        translations = [:]
        failed = []
        pending = []
        wholeProgress = nil
        draining = false
        stale = true
    }

    // MARK: 錄音中自動翻譯

    func startAuto(transcript: @escaping @MainActor () -> [TranscriptLine], language: @escaping @MainActor () -> TranscriptionLanguage) {
        liveTranscript = transcript
        liveLanguage = language
        autoPaused = false
        startLoop()
    }

    private func startLoop() {
        stopAuto()
        guard isEnabled, liveTranscript != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self, let t = self.liveTranscript, let l = self.liveLanguage else { return }
                self.sync(transcript: t(), language: l(), enqueue: true)
            }
        }
    }

    func stopAuto() {
        loop?.cancel()
        loop = nil
    }

    /// 錄音結束:把剩下的定稿行最後送一批,然後停排程。
    func endAuto() {
        if let t = liveTranscript, let l = liveLanguage, isEnabled {
            draining = true
            sync(transcript: t(), language: l(), enqueue: true, force: true)
        }
        stopAuto()
        liveTranscript = nil
        liveLanguage = nil
    }

    // MARK: 送出

    private func flushIfDue(force: Bool) {
        guard isAvailable, !isTranslating, let p = provider else { return }
        if autoPaused && !force { return }
        let cadence: TimeInterval = isApple ? 0 : TimeInterval(cadenceSeconds)
        guard TranslationPlan.shouldFlush(cadence: cadence, lastSentAt: lastSentAt, now: Date(), pendingCount: pending.count, force: force) else { return }
        let keepGoing = isApple || force || draining
        Task { await runBatch(provider: p, continueDraining: keepGoing) }
    }

    private func runBatch(provider p: any TranslationProvider, continueDraining: Bool) async {
        let (batch, rest) = TranslationPlan.nextBatch(pending)
        guard !batch.isEmpty else { return }
        pending = rest
        let ids = batch.map(\.id)
        inFlight.formUnion(ids)
        isTranslating = true
        lastSentAt = Date()
        batchCount += 1
        let from = sourceLanguage.resolved().language
        do {
            let r = try await p.translate(batch.map(\.text), from: from, to: target.language)
            for (line, t) in zip(batch, r.lines) { translations[line.id] = t }
            inputTokens += r.inputTokens
            outputTokens += r.outputTokens
            consecutiveFailures = 0
            autoPaused = false
            lastError = nil
            stale = false
            write()
            Self.log.notice("translation: batch ok lines=\(batch.count) in=\(r.inputTokens) out=\(r.outputTokens) ms=\(r.durationMs) backend=\(self.backendID)")
            // #2623 TOK-02:成功後追加一筆(Apple 翻譯 0 tokens,但次數看得到)。
            if let s = stem, !TokenLedger.append(stem: s, TokenEntry(feature: .translation, backend: backendID, inputTokens: r.inputTokens,
                                                                      outputTokens: r.outputTokens, durationMs: r.durationMs, units: batch.count)) {
                Self.log.error("tokens: append failed (translation)")
            }
        } catch {
            failed.formUnion(ids)
            consecutiveFailures += 1
            lastError = Self.message(for: error)
            Self.log.notice("translation: batch failed lines=\(batch.count) failures=\(self.consecutiveFailures) error=\(String(describing: error))")
            if MinutesRolling.shouldPauseAuto(consecutiveFailures: consecutiveFailures, manual: false) {
                autoPaused = true
                draining = false
            }
        }
        inFlight.subtract(ids)
        isTranslating = false
        if let wp = wholeProgress {
            wholeProgress = (wp.done + batch.count, wp.total)
            if pending.isEmpty { wholeProgress = nil; draining = false }
        }
        if pending.isEmpty { draining = false }
        if continueDraining, !pending.isEmpty, !autoPaused, let p2 = provider {
            await runBatch(provider: p2, continueDraining: true)
        }
    }

    /// 譯文檔:與原 `.srt` 同時間碼,只換文字;原子寫(TRL-08)。
    private func write() {
        guard let s = stem, !currentLines.isEmpty else { return }
        let url = SidecarSet.url(stem: s, ext: target.fileExtension)
        let text = SRT.make(from: TranslationSRT.lines(original: currentLines, translations: translations))
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            Self.log.error("translation: write failed \(error)")
        }
    }

    var fileURL: URL? { stem.map { SidecarSet.url(stem: $0, ext: target.fileExtension) } }

    /// TRL-10:錯誤只給一句介面文字,不含 CLI 原始輸出。
    static func message(for error: Error) -> String {
        guard let e = error as? TranslationError else { return "\(error)" }
        switch e {
        case .cliNotFound: return L("找不到 claude 指令,請先安裝 Claude Code")
        case .notLoggedIn: return L("Claude Code 尚未登入,請在終端機執行 claude /login")
        case .codexNotFound: return L("找不到 codex 指令,請先安裝 Codex CLI")
        case .codexNotLoggedIn: return L("Codex CLI 尚未登入,請在終端機執行 codex login")
        case .timeout: return L("翻譯逾時,請稍後再試")
        case .badOutput(let s): return Lf("翻譯回應無法解析:%@", [s])
        case .failed(let code, let s): return Lf("翻譯失敗(exit %@):%@", ["\(code)", s])
        case .unavailable(let s): return s.isEmpty ? L("Apple 翻譯目前無法使用") : L(s)
        }
    }
}
