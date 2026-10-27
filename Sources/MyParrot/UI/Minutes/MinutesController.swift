import Foundation
import Observation
import os
import MyParrotCore

/// #2438 E／F3／G1 會議記錄的 App 層狀態機(Phase 1 shell、Phase 2 接真後端)。
/// 後端來自 `ModelBackendRegistry.selected(for: .minutes)`:Claude CLI(Phase 2,MIN-01)、DEBUG 的 `localFake`;
/// 其他 ⇒ `isAvailable == false` ⇒ 會議記錄欄與圖示根本不出現(B2)。自動更新每 N 分(偏好 `minutes.cadence` 2～15,
/// 預設 5;`minutes.auto` 預設開),手動「立即更新」,結束錄音時最後跑一次。產出寫 `<stem>.minutes.md`(Markdown)與
/// `<stem>.minutes.json`(結構化),唯讀草稿,🚫 不動任何人寫的檔。
///
/// Phase 2 新增:MIN-04 空輪次不呼叫(沒新定稿行且筆記沒變);MIN-05 連續 3 次失敗自動暫停、手動成功一次恢復;
/// MIN-08 `--model` 每次呼叫時再讀共用欄位;MIN-09 `transcriptLinesConsumed` 落在 JSON,重新附著從上次吃到的行數接續。
@MainActor
@Observable
final class MinutesController {
    static let cadenceKey = "minutes.cadence"
    static let autoKey = "minutes.auto"
    static let cadenceRange = 2...15
    /// MIN-08:與校正層共用的 Claude CLI 模型檔位欄位(`RecordingController.correctionModel` 寫的那把鍵)。
    static let cliModelKey = "correctionModel"
    /// #2418 CDX-08:Codex CLI 的檔位欄位(`RecordingController.codexModel` 寫的那把鍵),與 Claude 的分開。
    static let codexModelKey = "codexModel"

    var document: MinutesDocument?
    var lastUpdate: Date?
    var isUpdating = false
    var lastError: String?
    var inputTokens = 0
    var outputTokens = 0
    /// MIN-05:連續失敗次數;自動模式到門檻 ⇒ `autoPaused`。
    private(set) var consecutiveFailures = 0
    private(set) var autoPaused = false
    /// 後端選了、但這台跑不起來的原因(找不到 claude);nil＝沒問題或後端關閉。
    private(set) var unavailableReason: String?
    /// 目前解析到的後端 id(off／claudeCLI／codexCLI／appleFM／localFake)。
    private(set) var backendID: String = ModelBackendRegistry.offID
    /// 目前附著的錄音 stem(`<dir>/<日期 時間 標題>`,不含副檔名);nil＝待錄音。
    private(set) var stem: URL?
    /// MIN-09:這場記錄已吃到逐字稿的第幾行。
    private(set) var transcriptLinesConsumed = 0

    var cadenceMinutes: Int {
        didSet {
            let c = min(Self.cadenceRange.upperBound, max(Self.cadenceRange.lowerBound, cadenceMinutes))
            if c != cadenceMinutes { cadenceMinutes = c; return }
            defaults.set(cadenceMinutes, forKey: Self.cadenceKey)
        }
    }
    var autoEnabled: Bool {
        didSet { defaults.set(autoEnabled, forKey: Self.autoKey) }
    }

    struct AutoSources {
        var transcript: @MainActor () -> [TranscriptLine]
        var notes: @MainActor () -> String
        var language: @MainActor () -> TranscriptionLanguage
    }

    /// `.minutes.md` 的段落標題:App 層(NotesSession)用 `L()` 填,跟介面語言走;Core 預設英文。
    @ObservationIgnored var fileLabels: MinutesLabels = .english
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var provider: (any MinutesProvider)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 錄音中自動更新的來源;MIN-05 暫停後手動成功要靠它恢復。錄音結束 ⇒ nil。
    @ObservationIgnored private var autoSources: AutoSources?
    /// MIN-04:上次成功送出時的筆記 hash(同一行程內穩定)。
    @ObservationIgnored private var lastNotesHash: Int?
    @ObservationIgnored private static let log = Logger(subsystem: "tw.uncle.MyParrot", category: "minutes")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let c = defaults.object(forKey: Self.cadenceKey) == nil ? 5 : defaults.integer(forKey: Self.cadenceKey)
        cadenceMinutes = min(Self.cadenceRange.upperBound, max(Self.cadenceRange.lowerBound, c))
        autoEnabled = defaults.object(forKey: Self.autoKey) == nil ? true : defaults.bool(forKey: Self.autoKey)
        refreshProvider()
    }

    /// 有後端才算「可用」;設定頁改了後端要再呼叫一次。
    var isAvailable: Bool { provider != nil }

    /// 這個建置真的會產會議記錄的後端(report-M6 題 A 裁示 A2:設定頁只列這些,G1 第 1 條「沒設供應商功能不出現」)。
    /// Phase 2:Claude CLI 接上;Apple Foundation Models 挪 Phase 3(Eric 2026-10-19 22:31 A2)。
    static var implementedBackendIDs: Set<String> {
        var ids: Set<String> = [ModelBackendRegistry.offID, ModelBackendRegistry.claudeCLI.id, ModelBackendRegistry.codexCLI.id]   // #2418 CDX
        // #2438 Phase 3a:Apple Foundation Models(macOS 26+ 才進表;可不可用另看 AppleFMAvailability)。
        if AFMAvailability.isPlatformSupported { ids.insert(ModelBackendRegistry.appleFM.id) }
        #if DEBUG
        ids.insert("localFake")
        #endif
        return ids
    }

    /// #2483 C(TRX-04):高精度重轉把逐字稿整份換掉 ⇒ 吃到的行數歸零(記錄本體不動),下次「產生／立即更新」
    /// 會把整份新稿連同上一版記錄一起送,等於用高精度稿重新整理。
    func rebase() {
        transcriptLinesConsumed = 0
        if var d = document { d.transcriptLinesConsumed = 0; document = d; write(d, labels: fileLabels) }
        Self.log.notice("minutes: rebase after re-transcription (consumed → 0)")
    }

    func refreshProvider() {
        let selected = ModelBackendRegistry.selected(for: .minutes, defaults: defaults)
        backendID = selected.id
        unavailableReason = nil
        #if DEBUG
        if selected.id == "localFake" { provider = LocalFakeMinutesProvider(); return }
        #endif
        if selected.id == ModelBackendRegistry.appleFM.id {
            // #2438 Phase 3a(AFM-01/06):每次都重探;不可用 ⇒ 選擇保留、講原因、不建 provider。
            let afm = AppleFMAvailability.shared
            afm.refresh()
            #if canImport(FoundationModels)
            if afm.isAvailable, #available(macOS 26, *) { provider = AppleFMMinutesProvider(); return }
            #endif
            provider = nil
            unavailableReason = afm.message ?? L("Apple 本機模型目前無法使用")
            return
        }
        if selected.id == ModelBackendRegistry.codexCLI.id {
            // #2418 CDX-02/03:第三個後端;找不到 codex ⇒ 選擇保留、講原因、不建 provider。
            if let exe = CodexCLIProvider.locate() {
                provider = CodexCLIMinutesProvider(executable: exe, model: defaults.string(forKey: Self.codexModelKey), timeout: 120)
            } else {
                provider = nil
                unavailableReason = L("找不到 codex 指令,請先安裝 Codex CLI")
            }
            return
        }
        if selected.id == ModelBackendRegistry.claudeCLI.id {
            if let exe = ClaudeCLIProvider.locate() {
                provider = ClaudeCLIMinutesProvider(executable: exe, model: cliModel, timeout: 120)
            } else {
                provider = nil
                unavailableReason = L("找不到 claude 指令,請先安裝 Claude Code")
            }
            return
        }
        provider = nil
    }

    private var cliModel: String? { defaults.string(forKey: Self.cliModelKey) }

    // MARK: 附著

    /// 換到某場錄音:讀既有 `.minutes.json`(有就顯示、從它吃到的行數接續),失敗計數歸零。
    func attach(stem newStem: URL?) {
        stopAuto()
        autoSources = nil
        stem = newStem
        transcriptLinesConsumed = 0
        lastNotesHash = nil
        lastError = nil
        document = nil
        lastUpdate = nil
        consecutiveFailures = 0
        autoPaused = false
        guard let s = newStem else { return }
        let json = SidecarSet.url(stem: s, ext: "minutes.json")
        if let data = try? Data(contentsOf: json),
           let doc = try? Self.decoder.decode(MinutesDocument.self, from: data) {
            document = doc
            lastUpdate = doc.updatedAt
            transcriptLinesConsumed = doc.transcriptLinesConsumed
        }
    }

    // MARK: 自動更新

    /// 錄音中每 N 分呼叫一次 `update`(取用時才讀逐字稿與筆記,所以用 closure)。
    func startAuto(transcript: @escaping @MainActor () -> [TranscriptLine], notes: @escaping @MainActor () -> String,
                   language: @escaping @MainActor () -> TranscriptionLanguage) {
        autoSources = AutoSources(transcript: transcript, notes: notes, language: language)
        autoPaused = false
        startLoop()
    }

    private func startLoop() {
        stopAuto()
        guard autoEnabled, provider != nil, let src = autoSources else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.cadenceMinutes * 60))
                if Task.isCancelled { return }
                await self.update(transcript: src.transcript(), notes: src.notes(), language: src.language(), manual: false)
            }
        }
    }

    func stopAuto() {
        loop?.cancel()
        loop = nil
    }

    /// 錄音結束:停排程、丟掉自動來源(之後只剩手動)。
    func endAuto() {
        stopAuto()
        autoSources = nil
        autoPaused = false
    }

    // MARK: 更新

    /// 跑一次滾動摘要:上一版記錄＋自上次之後的逐字稿(只取定稿行)＋筆記全文 → 新記錄,寫兩個 sidecar。
    /// `manual == false`(自動排程、結束時最後一次)才適用 MIN-04 跳過與 MIN-05 自動暫停。
    func update(transcript: [TranscriptLine], notes: String, language: TranscriptionLanguage,
                speakerYou: String = "You", speakerThem: String = "Them", manual: Bool = true) async {
        // AFM-06:每次更新前重探可用性;掉線就跳過這輪(不算失敗次數)、欄顯示原因。
        if backendID == ModelBackendRegistry.appleFM.id, !isUpdating {
            refreshProvider()
            if provider == nil { Self.log.notice("minutes: skipped: unavailable (appleFM)"); return }
        }
        guard var p = provider, !isUpdating else { return }
        // MIN-08:模型檔位欄位改了,下一次呼叫就生效(不必重選後端)。
        if var cli = p as? ClaudeCLIMinutesProvider { cli.model = (cliModel?.isEmpty == false) ? cliModel : nil; p = cli }
        let plan = MinutesRolling.plan(transcriptCount: transcript.count, consumed: transcriptLinesConsumed)
        let previous = plan.startOver ? nil : document
        let fresh = transcript.dropFirst(plan.from).filter { $0.isFinal }
        let delta = fresh.map { "\($0.isYou ? speakerYou : speakerThem) \(NotesDocument.timecode($0.start)): \($0.text)" }
        let notesHash = notes.hashValue
        let notesEmpty = MinutesRolling.notesIsEffectivelyEmpty(notes)
        if MinutesRolling.shouldSkip(manual: manual, deltaEmpty: delta.isEmpty,
                                     notesChanged: notesHash != lastNotesHash, notesEmpty: notesEmpty) {
            Self.log.notice("minutes: skip empty round (lines \(transcript.count), consumed \(self.transcriptLinesConsumed))")
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        let started = Date()
        let input = MinutesInput(previous: previous, transcriptDelta: delta, notes: notes, language: language)
        do {
            var doc = try await p.update(input)
            doc.transcriptLinesConsumed = transcript.count
            document = doc
            lastUpdate = doc.updatedAt
            inputTokens += doc.inputTokens
            outputTokens += doc.outputTokens
            transcriptLinesConsumed = transcript.count
            lastNotesHash = notesHash
            // #2623 TOK-02:成功後追加一筆到這場的帳本(Apple 本機模型＝估算)。
            if let s = stem, !TokenLedger.append(stem: s, TokenEntry(feature: .minutes, backend: backendID, inputTokens: doc.inputTokens,
                                                                      outputTokens: doc.outputTokens, durationMs: Int(Date().timeIntervalSince(started) * 1000),
                                                                      units: delta.count, estimated: backendID == ModelBackendRegistry.appleFM.id)) {
                Self.log.error("tokens: append failed (minutes)")
            }
            lastError = nil
            consecutiveFailures = 0
            write(doc, labels: fileLabels)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            // MIN-11:只記帳目,不記內容。
            Self.log.notice("minutes: ok backend=\(self.backendID, privacy: .public) in=\(doc.inputTokens) out=\(doc.outputTokens) newLines=\(delta.count) ms=\(ms) manual=\(manual)")
            if autoPaused { autoPaused = false; startLoop() }
        } catch {
            consecutiveFailures += 1
            lastError = Self.message(for: error)
            Self.log.error("minutes: failed #\(self.consecutiveFailures) manual=\(manual) \(String(describing: error), privacy: .public)")
            if MinutesRolling.shouldPauseAuto(consecutiveFailures: consecutiveFailures, manual: manual) {
                stopAuto()
                autoPaused = true
            }
        }
    }

    /// MIN-05:錯誤只給一句介面文字,不含 CLI 原始輸出。
    static func message(for error: Error) -> String {
        guard let e = error as? MinutesError else { return "\(error)" }
        switch e {
        case .cliNotFound: return L("找不到 claude 指令,請先安裝 Claude Code")
        case .notLoggedIn: return L("Claude Code 尚未登入,請在終端機執行 claude /login")
        case .codexNotFound: return L("找不到 codex 指令,請先安裝 Codex CLI")
        case .codexNotLoggedIn: return L("Codex CLI 尚未登入,請在終端機執行 codex login")
        case .timeout: return L("會議記錄更新逾時,請稍後再試")
        case .badOutput(let s): return Lf("會議記錄回應無法解析:%@", [s])
        case .failed(let code, let s): return Lf("會議記錄更新失敗(exit %@):%@", ["\(code)", s])
        }
    }

    /// 寫 `<stem>.minutes.json` 與 `<stem>.minutes.md`(原子寫);沒有 stem(待錄音)就只留在記憶體。
    func write(_ doc: MinutesDocument, labels: MinutesLabels = .english) {
        guard let s = stem else { return }
        do {
            let json = try Self.encoder.encode(doc)
            try json.write(to: SidecarSet.url(stem: s, ext: "minutes.json"), options: .atomic)
            try MinutesMarkdown.render(doc, labels: labels)
                .write(to: SidecarSet.url(stem: s, ext: "minutes.md"), atomically: true, encoding: .utf8)
        } catch {
            lastError = "\(error)"
        }
    }

    var markdownURL: URL? { stem.map { SidecarSet.url(stem: $0, ext: "minutes.md") } }

    func markdown(labels: MinutesLabels) -> String? { document.map { MinutesMarkdown.render($0, labels: labels) } }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
