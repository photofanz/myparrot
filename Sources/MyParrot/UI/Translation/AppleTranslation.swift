import SwiftUI
import Translation
import MyParrotCore

/// #2612 TRL-02／03:Apple Translation framework 後端。session 只能從 SwiftUI view 的 `.translationTask` 拿,所以
/// provider 住 App 層、由 `AppleTranslationHost` 在閉包活著期間交給 `TranslationController`;Core 不 import Translation。
/// 批次 API `translations(from:)`,`clientIdentifier`＝行序對回;回來少行 ⇒ 整批作廢(TRL-05 同規則)。零 token、不出機。
struct AppleTranslationProvider: TranslationProvider, @unchecked Sendable {
    let session: TranslationSession

    /// 語言包下載(系統框由使用者按);host 只透過 provider 碰 session,免得 session 被「送出」後又在閉包裡用(區域隔離檢查)。
    func prepare() async throws { try await session.prepareTranslation() }

    func translate(_ lines: [String], from: Locale.Language, to: Locale.Language) async throws -> TranslationResult {
        let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let responses: [TranslationSession.Response]
        do { responses = try await session.translations(from: requests) } catch {
            throw TranslationError.failed(-1, "Apple 翻譯失敗")
        }
        var out = Array(repeating: "", count: lines.count)
        for r in responses {
            if let id = r.clientIdentifier, let i = Int(id), i >= 0, i < out.count { out[i] = r.targetText }
        }
        if out.contains(where: { $0.isEmpty }) { throw TranslationError.badOutput("行數不符") }
        return TranslationResult(lines: out)
    }
}

/// 隱形 view:掛在逐字稿欄裡。(1) 探語言包狀態(後端／來源／目標語言變、或 `availabilityProbe` +1 時重探);
/// (2) 後端是 Apple 時建 `TranslationSession.Configuration`,translationTask 閉包活著期間每 0.25 s 叫一次 `applePump()`,
/// 並代按「下載語言包」(`prepareTranslation()`,系統框由使用者按)。閉包結束 ⇒ 收回 provider。
struct AppleTranslationHost: View {
    @Bindable var translation: TranslationController
    let source: Locale.Language
    @State private var config: TranslationSession.Configuration?

    private var probeKey: String {
        "\(translation.backendID)|\(source.minimalIdentifier)|\(translation.target.rawValue)|\(translation.availabilityProbe)"
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: probeKey) { await probe() }
            .translationTask(config) { session in
                // 閉包不在 MainActor:provider 先在本地包好(Sendable)再交給 @MainActor 的 controller。
                let provider = AppleTranslationProvider(session: session)
                await translation.appleSessionReady(provider)
                while !Task.isCancelled {
                    if await translation.wantsLanguageDownload {
                        await MainActor.run { translation.wantsLanguageDownload = false }
                        do { try await provider.prepare() } catch {
                            await MainActor.run { translation.lastError = L("Apple 翻譯目前無法使用") }
                        }
                        await probe()
                    }
                    await translation.applePump()
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await translation.appleSessionGone()
            }
    }

    private func probe() async {
        guard translation.isApple else {
            config = nil
            translation.setAvailability(.notApplicable)
            return
        }
        let target = translation.target.language
        let same = source.languageCode == target.languageCode && (source.script == target.script || source.script == nil || target.script == nil)
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: translation.setAvailability(.installed, sourceSameAsTarget: same)
        case .supported: translation.setAvailability(.supported, sourceSameAsTarget: same)
        case .unsupported: translation.setAvailability(.unsupported, sourceSameAsTarget: same)
        @unknown default: translation.setAvailability(.unknown, sourceSameAsTarget: same)
        }
        if config == nil || config?.source != source || config?.target != translation.target.language {
            config = TranslationSession.Configuration(source: source, target: translation.target.language)
        }
    }
}

/// 逐字稿欄標題列的「譯 → 繁中 ▾」(TRL-07):翻譯後端 off 時整顆不出現。選目標語言、顯示／隱藏譯文、立即翻譯、重送未譯;
/// 右邊帶待翻數。
struct TranslationControl: View {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState

    var body: some View {
        if let tr = uiState.notes?.translation, tr.isEnabled {
            Menu {
                Picker(L("目標語言"), selection: Binding(get: { tr.target }, set: { tr.target = $0 })) {
                    ForEach(TranslationTarget.allCases, id: \.self) { Text(L($0.label)).tag($0) }
                }
                Toggle(L("顯示譯文"), isOn: Binding(get: { tr.showTranslations }, set: { tr.showTranslations = $0 }))
                Divider()
                Button(L("立即翻譯")) { tr.translateNow() }
                    .disabled(!tr.isAvailable || (tr.pending.isEmpty && controller.state != .recording && controller.state != .paused))
                Button(L("翻譯整份")) { uiState.notes?.translateWholeNow(controller: controller) }
                    .disabled(!tr.isAvailable || controller.liveTranscript.isEmpty)
                if !tr.failed.isEmpty { Button(L("重送未譯")) { tr.retryAllFailed() } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "character.bubble")
                    Text("\(L("譯")) → \(L(tr.target.shortLabel))")
                    let busy = tr.pending.count + tr.inFlight.count
                    if busy > 0 { Text("\(busy)").monospacedDigit().foregroundStyle(.secondary) }
                    if tr.autoPaused { Image(systemName: "pause.circle").foregroundStyle(.orange) }
                }
                .font(MPFont.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(tr.unavailableReason ?? (tr.autoPaused ? L("自動翻譯已暫停,按立即翻譯重試") : L("逐字稿翻譯")))
        }
    }
}
