import Foundation
import os

/// 校正層在 UI 上的一則建議(CORR-08):建議本體＋狀態。接受前檔案不動;接受才改寫
/// sidecar;還原把它換回去。
public struct PendingCorrection: Identifiable, Sendable, Hashable {
    public enum State: Sendable { case pending, accepted, ignored }
    public let id: String
    public var suggestion: CorrectionSuggestion
    public var state: State = .pending
}

/// #2417 逐字稿校正層的流程(CORR-01~14)。狀態欄位在 `RecordingController` 本體
/// (stored property 不能放 extension),流程全在這裡。
@MainActor
extension RecordingController {

    /// 依設定組後端(CORR-02):關閉 ⇒ nil(什麼都不建、不 spawn);找不到 CLI ⇒ 丟錯。
    /// 測試可用 `correctionProviderOverride` 注入(例如指向假的 `claude` 腳本)。
    public func makeCorrectionProvider() throws -> (any CorrectionProvider)? {
        if let o = correctionProviderOverride { return o }
        switch correctionBackend {
        case .off: return nil
        #if DEBUG
        case .localFake: return LocalFakeProvider()   // MDL-04:假供應商只在 DEBUG 建置存在
        #endif
        case .claudeCLI:
            guard let exe = ClaudeCLIProvider.locate() else { throw CorrectionError.cliNotFound }
            return ClaudeCLIProvider(executable: exe, model: correctionModel)
        case .codexCLI:
            // #2418 CDX-02/03:第三個後端,只多這一個 case;找不到 codex ⇒ 丟錯(入口由設定頁狀態列講原因)。
            guard let exe = CodexCLIProvider.locate() else { throw CorrectionError.codexNotFound }
            return CodexCLIProvider(executable: exe, model: codexModel)
        case .appleFM:
            // #2438 Phase 3a(AFM-01):每次建 provider 前都探一次可用性;不可用 ⇒ 丟原因,不假裝能用。
            let status = AFMAvailability.probe()
            guard status == .available else {
                throw CorrectionError.unavailable(AFMAvailability.messageKey(for: status) ?? "Apple 本機模型目前無法使用")
            }
            #if canImport(FoundationModels) && !MYPARROT_NO_AFM
            if #available(macOS 26, *) { return AppleFMCorrectionProvider() }
            #endif
            throw CorrectionError.unavailable(AFMAvailability.messageKey(for: .unsupportedOS) ?? "")
        }
    }

    /// 把一筆既有錄音的 `.srt` 讀回畫面(校正要有行可改)。成功 ⇒ `liveTranscript`
    /// 與 `transcriptSource` 都指到它;失敗回 false、什麼都不動。
    @discardableResult
    public func loadTranscript(for rec: Recording) -> Bool {
        let srt = rec.url.deletingPathExtension().appendingPathExtension("srt")
        guard let text = try? String(contentsOf: srt, encoding: .utf8) else { return false }
        let lines = SRT.parse(text)
        guard !lines.isEmpty else { return false }
        // 10/22:SRT 只有偏移秒數,`time` 要以錄音起點為基準才會顯示正確牆鐘(否則全是 epoch 的 08:00)。
        let base = rec.startDate
        liveTranscript = lines.map { var l = $0; l.time = base.addingTimeInterval(l.start); return l }
        transcriptSource = rec
        correctionSuggestions = []
        return true
    }

    /// 「檢查逐字稿」:分批送給後端 → `validate` → 列給人看。**不改任何檔**。
    public func checkTranscript() async {
        guard !isCheckingTranscript, transcriptSource != nil, !liveTranscript.isEmpty else { return }
        let provider: (any CorrectionProvider)?
        do { provider = try makeCorrectionProvider() } catch let e as CorrectionError {
            lastError = e.zhTW; return
        } catch { lastError = "\(error)"; return }
        guard let provider else { return }                   // 開關關閉:什麼都不做
        isCheckingTranscript = true
        defer { isCheckingTranscript = false }
        lastError = nil
        let segments = liveTranscript.map(\.text)
        var collected: [CorrectionSuggestion] = []
        var inTok = 0, outTok = 0, ms = 0
        for range in CorrectionRules.batches(count: segments.count, size: Self.correctionBatchSize) {
            do {
                let r = try await provider.suggest(segments: segments, range: range, language: language)
                collected += CorrectionRules.validate(r.suggestions, segments: segments, range: range)
                inTok += r.inputTokens; outTok += r.outputTokens; ms += r.durationMs
                // #2623 TOK-02:每批成功後追加一筆到這場的帳本(只記數字);寫失敗只記 log。
                if let src = transcriptSource,
                   !TokenLedger.append(stem: SidecarSet.stem(of: src.url),
                                       TokenEntry(feature: .correction, backend: correctionBackend.rawValue, inputTokens: r.inputTokens,
                                                  outputTokens: r.outputTokens, durationMs: r.durationMs, units: range.count,
                                                  estimated: correctionBackend == .appleFM)) {
                    Logger(subsystem: "tw.uncle.MyParrot", category: "tokens").error("tokens: append failed (correction)")
                }
            } catch let e as CorrectionError {
                lastError = e.zhTW; break                      // 一則提示、不重試、不改檔(CORR-09)
            } catch {
                lastError = "校正失敗:\(error)"; break
            }
        }
        // CORR-14 額度帳:只記數字,不記內容。
        lastCorrectionUsage = CorrectionUsage(inputTokens: inTok, outputTokens: outTok, durationMs: ms, batches: collected.isEmpty ? 0 : 1)
        // 統一日誌＋一個使用者看得到的檔(`~/Library/Logs/MyParrot/correction.log`),兩邊都只記數字不記內容。
        // (實測 `log show` 在自動化環境常讀不到統一日誌,檔案才是可靠的驗證尺。)
        let line = "segments=\(segments.count) suggestions=\(collected.count) input=\(inTok) output=\(outTok) ms=\(ms)"
        Logger(subsystem: "tw.uncle.MyParrot", category: "correction").notice("\(line, privacy: .public)")
        Self.appendCorrectionLog(line)
        // id 給 UI/通道用,不能含 \u{1F}(DEBUG 通道的分隔字元);同段同 original 已去重,所以唯一。
        correctionSuggestions = collected.map { PendingCorrection(id: "\($0.segment)#\($0.original)", suggestion: $0) }
    }

    public static let correctionBatchSize = 100

    /// CORR-14 額度帳落檔:`~/Library/Logs/MyParrot/correction.log`,每行「時間 數字」。
    public static var correctionLogURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MyParrot/correction.log")
    }
    static func appendCorrectionLog(_ line: String) {
        let url = correctionLogURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: data) }
        else { try? data.write(to: url) }
    }

    /// 接受一則:改記憶體裡那一行 → 重寫 `.txt`/`.srt`(原子寫)→ 狀態 accepted。
    /// 段落已被改到找不到 original ⇒ 不動、標 ignored(不騙人說改了)。
    public func acceptCorrection(_ id: String) {
        guard let i = correctionSuggestions.firstIndex(where: { $0.id == id }),
              correctionSuggestions[i].state == .pending else { return }
        let s = correctionSuggestions[i].suggestion
        guard s.segment < liveTranscript.count,
              let newText = CorrectionRules.apply(s, to: liveTranscript[s.segment].text) else {
            correctionSuggestions[i].state = .ignored; return
        }
        liveTranscript[s.segment].text = newText
        correctionSuggestions[i].state = .accepted
        rewriteTranscriptSidecar()
        // #2483 C(TRX-03):接受的校正持久化,重轉後重套。
        if let rec = transcriptSource {
            TranscriptHandoff.append(AcceptedCorrection(original: s.original, suggestion: s.suggestion, reason: s.reason,
                                                        at: liveTranscript[s.segment].start),
                                     stem: SidecarSet.stem(of: rec.url))
        }
    }

    /// 還原一則已接受的建議。
    public func revertCorrection(_ id: String) {
        guard let i = correctionSuggestions.firstIndex(where: { $0.id == id }),
              correctionSuggestions[i].state == .accepted else { return }
        let s = correctionSuggestions[i].suggestion
        guard s.segment < liveTranscript.count,
              let newText = CorrectionRules.revert(s, in: liveTranscript[s.segment].text) else { return }
        liveTranscript[s.segment].text = newText
        correctionSuggestions[i].state = .pending
        rewriteTranscriptSidecar()
        if let rec = transcriptSource {
            TranscriptHandoff.remove(original: s.original, suggestion: s.suggestion, stem: SidecarSet.stem(of: rec.url))
        }
    }

    public func ignoreCorrection(_ id: String) {
        guard let i = correctionSuggestions.firstIndex(where: { $0.id == id }),
              correctionSuggestions[i].state == .pending else { return }
        correctionSuggestions[i].state = .ignored
    }

    public func ignoreAllCorrections() {
        for i in correctionSuggestions.indices where correctionSuggestions[i].state == .pending {
            correctionSuggestions[i].state = .ignored
        }
    }

    public func clearCorrections() { correctionSuggestions = [] }

    private func rewriteTranscriptSidecar() {
        guard let rec = transcriptSource else { return }
        writeTranscriptSidecar(liveTranscript, for: rec)
    }
}

/// CORR-14:一次「檢查逐字稿」的額度帳。
public struct CorrectionUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int
    public var batches: Int
}
