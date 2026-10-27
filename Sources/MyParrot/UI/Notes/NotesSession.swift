import Foundation
import AppKit
import Observation
import MyParrotCore

/// #2438 M5：筆記與會議記錄「跟著哪一場」的膠水（plan §3.5「文件切換」）。
/// - 待錄音 ⇒ 草稿 `<dir>/.draft.notes.md`；開錄 ⇒ 草稿改名成那場的 `<stem>.notes.md`；
/// - 錄音中／暫停中 ⇒ 鎖在進行中那場（選別場不切）；結束後或點選列 ⇒ 讀那場的筆記與 `.minutes.json`。
/// 切換前一律 `flush()`；QUIT 時 `flushAll()`。標記／引用／貼到筆記都從這裡進字。
@MainActor
@Observable
final class NotesSession {
    let store: NotesStore
    let proxy = NotesEditorProxy()
    let minutes = MinutesController()
    /// #2612 TRL:逐字稿翻譯,跟著同一場走(attach 與會議記錄同步)。
    let translation = TranslationController()
    /// #2623 TOK:這場的帳本(附著時讀;`TokenLedger.didChange` 到就重讀)。
    private(set) var tokens: [TokenEntry] = []
    @ObservationIgnored private var tokenObserver: NSObjectProtocol?
    /// 目前顯示的那場 stem；nil＝草稿。
    private(set) var stem: URL?
    var isDraft: Bool { stem == nil }
    /// 錄音中／暫停中鎖住的那場（nil＝沒鎖）。
    private(set) var lockedStem: URL?
    private(set) var recordingsDir: URL

    init(recordingsDir: URL, store: NotesStore = NotesStore()) {
        self.recordingsDir = recordingsDir
        self.store = store
        minutes.fileLabels = Self.localizedLabels()
        // 觀察者活到 app 結束(NotesSession 單一實例);Notification 非 Sendable,先把 stem(URL)取出再進 MainActor。
        tokenObserver = NotificationCenter.default.addObserver(forName: TokenLedger.didChange, object: nil, queue: .main) { [weak self] note in
            let changed = note.userInfo?[TokenLedger.stemKey] as? URL
            MainActor.assumeIsolated {
                guard let self, let s = changed, s == self.stem else { return }
                self.reloadTokens()
            }
        }
    }

    // MARK: #2623 TOK-04 本場模型用量

    func reloadTokens() {
        tokens = stem.map { TokenLedger.load(stem: $0) } ?? []
    }

    /// 逐字稿欄底部那一行(Eric 10/27 12:37「那一行也分後端」):「本場模型用量 校正 Claude 2.0k · 記錄 Codex 14.7k」;
    /// 能力 × 後端各一段(同能力兩家都用過就各列),只列 tokens >0 的,估算前加 ≈;全 0 ⇒ nil。
    var tokenSummaryLine: String? {
        let t = TokenLedger.totals(tokens)
        let order: [(ModelCapability, String)] = [(.correction, L("校正")), (.minutes, L("記錄")), (.translation, L("翻譯"))]
        var parts: [String] = []
        for (cap, label) in order {
            guard let backends = t.byFeatureBackend[cap.rawValue] else { continue }
            for (backend, s) in backends.sorted(by: { $0.value.total > $1.value.total }) where s.total > 0 {
                parts.append("\(label) \(Self.backendShort(backend)) \(s.estimated ? "≈" : "")\(TokenLedger.format(s.total))")
            }
        }
        return parts.isEmpty ? nil : L("本場模型用量") + " " + parts.joined(separator: " · ")
    }

    /// 後端短名(品牌字不翻譯):claudeCLI→Claude、codexCLI→Codex、appleFM／appleTranslation→Apple、其他原樣。
    static func backendShort(_ id: String) -> String {
        switch id {
        case ModelBackendRegistry.claudeCLI.id: return "Claude"
        case ModelBackendRegistry.codexCLI.id: return "Codex"
        case ModelBackendRegistry.appleFM.id, ModelBackendRegistry.appleTranslation.id: return "Apple"
        default: return id
        }
    }

    /// 會議記錄四段＋時間軸的介面文字(面板、複製、`.minutes.md` 共用一份)。
    static func localizedLabels() -> MinutesLabels {
        MinutesLabels(summary: L("摘要"), decisions: L("決議"), actions: L("待辦"), questions: L("待釐清"),
                      timeline: L("時間軸"), empty: "—")
    }

    // MARK: 文件切換

    /// 待錄音：顯示草稿（檔不存在＝空，不建檔）。
    func showDraft() {
        guard store.load(url: NotesDocument.draftURL(in: recordingsDir)) else { return }
        stem = nil
        minutes.attach(stem: nil)
        translation.attach(stem: nil)
        reloadTokens()
    }

    /// 開錄：草稿改名成該場筆記並鎖住；`title` nil ⇒ 用 stem 的標題部分。
    func recordingStarted(url: URL, title: String?) {
        let s = SidecarSet.stem(of: url)
        let t = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        _ = store.attachDraft(to: s, title: t)
        stem = s
        lockedStem = s
        minutes.attach(stem: s)
        translation.attach(stem: s)
        reloadTokens()
    }

    /// 停錄：解鎖（仍顯示那場）。
    func recordingStopped() {
        lockedStem = nil
        _ = store.flush()
    }

    /// 顯示某場（結束後或點選列）；錄音中被鎖住時忽略。回 false＝被鎖或切不過去（flush 失敗）。
    @discardableResult
    func show(recording url: URL) -> Bool {
        let s = SidecarSet.stem(of: url)
        if let l = lockedStem, l != s { return false }
        if stem == s { return true }
        guard store.load(url: NotesDocument(stem: s).url) else { return false }
        stem = s
        minutes.attach(stem: s)
        translation.attach(stem: s)
        reloadTokens()
        return true
    }

    /// 改名後把筆記指到新路徑（檔已由 `RecordingController.rename` 搬走）。
    func renamed(from oldURL: URL, to newURL: URL) {
        let old = SidecarSet.stem(of: oldURL), new = SidecarSet.stem(of: newURL)
        if stem == old {
            store.retarget(to: NotesDocument(stem: new).url)
            stem = new
            minutes.attach(stem: new)
            translation.attach(stem: new)
            reloadTokens()
        }
        if lockedStem == old { lockedStem = new }
    }

    /// 丟垃圾桶後：若正顯示那場就脫離（不再往舊路徑寫）。
    func trashed(_ url: URL) {
        if stem == SidecarSet.stem(of: url) {
            store.detach()
            stem = nil
            minutes.attach(stem: nil)
            translation.attach(stem: nil)
            reloadTokens()
        }
    }

    func flushAll() { _ = store.flush() }

    // MARK: 選單／DebugControl 用

    enum MinutesTranscriptSource { case live, file, none }

    /// MIN-09:會議記錄要用哪份逐字稿。顯示中那場＝進行中／剛結束的錄音,或校正層已載入的那場 ⇒ `liveTranscript`;
    /// 否則讀該場自己的 `.srt`(不動 `liveTranscript`／`transcriptSource`,免得牽動校正層);沒有 `.srt` ⇒ `.none`。
    func minutesTranscript(controller: RecordingController) -> (lines: [TranscriptLine], source: MinutesTranscriptSource) {
        guard let s = stem else { return ([], .none) }
        if let cur = controller.currentRecordingURL, SidecarSet.stem(of: cur) == s { return (controller.liveTranscript, .live) }
        if let src = controller.transcriptSource, SidecarSet.stem(of: src.url) == s { return (controller.liveTranscript, .live) }
        let srt = SidecarSet.url(stem: s, ext: "srt")
        guard let text = try? String(contentsOf: srt, encoding: .utf8) else { return ([], .none) }
        let lines = SRT.parse(text)
        return (lines, lines.isEmpty ? .none : .file)
    }

    /// 「產生會議記錄」能不能按:有附著的場,而且找得到逐字稿來源(進行中的場就算還沒有行也算)。
    func canGenerateMinutes(controller: RecordingController) -> Bool {
        minutesTranscript(controller: controller).source != .none
    }

    /// 立即更新會議記錄(⌘⇧U、結束後一鍵、自動排程都走這裡)。`manual == false`＝結束時最後一次(適用 MIN-04 跳過規則)。
    func updateMinutesNow(controller: RecordingController, manual: Bool = true) async {
        let t = minutesTranscript(controller: controller)
        await minutes.update(transcript: t.lines, notes: store.text, language: controller.language,
                             speakerYou: L("你"), speakerThem: L("對方"), manual: manual)
    }

    /// 連結 ⌘K(與工具列同一條規則):剪貼簿是網址 ⇒ `[選取](網址)`,否則 `[選取](url)` 並選中 url。
    func insertLinkFromClipboard() {
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isURL = MarkdownEditing.isLikelyURL(clip)
        proxy.apply { MarkdownEditing.insertLink($0, selection: $1, url: isURL ? clip : "url", clipboardIsURL: isURL) }
        proxy.focus()
    }

    /// #2612 TRL-09:翻譯整份——用會議記錄同一套「哪份逐字稿」規則(進行中／已載入 ⇒ liveTranscript;否則讀該場 .srt)。
    func translateWholeNow(controller: RecordingController) {
        // 畫面上有載入的稿但這個 session 還沒附著那場(選單／DebugControl 路徑)⇒ 先附著,譯文檔才有 stem 可寫。
        if stem == nil, let src = controller.transcriptSource { _ = show(recording: src.url) }
        let t = minutesTranscript(controller: controller)
        guard !t.lines.isEmpty else { return }
        translation.translateWhole(lines: t.lines, language: controller.language)
    }

    /// 複製會議記錄 Markdown ⌘⇧C。
    func copyMinutesMarkdown() {
        guard let md = minutes.markdown(labels: Self.localizedLabels()) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    // MARK: 進字

    /// 標記 ⌘⇧M：編輯器有焦點 ⇒ 插在游標處；否則接在文末（自成一行）。
    func insertMarker(elapsed: TimeInterval) {
        let snippet = NotesDocument.marker(at: elapsed)
        if proxy.isFocused, proxy.apply({ MarkdownEditing.insert($0, selection: $1, snippet: snippet) }) { return }
        appendLine(snippet)
    }

    /// 逐字稿「引用到筆記」：`> <講者> h:mm:ss：…`。
    func appendQuote(speakerLabel: String, elapsed: TimeInterval, text: String) {
        appendBlock(NotesDocument.quote(speakerLabel: speakerLabel, elapsed: elapsed, text: text))
    }

    /// 會議記錄「貼到筆記」：整段 Markdown 接在文末。
    func appendBlock(_ block: String) {
        var t = store.text
        if !t.isEmpty && !t.hasSuffix("\n") { t += "\n" }
        if !t.isEmpty && !t.hasSuffix("\n\n") { t += "\n" }
        t += block.hasSuffix("\n") ? block : block + "\n"
        store.setText(t)
    }

    private func appendLine(_ line: String) {
        var t = store.text
        if !t.isEmpty && !t.hasSuffix("\n") { t += "\n" }
        t += line + "\n"
        store.setText(t)
    }
}
