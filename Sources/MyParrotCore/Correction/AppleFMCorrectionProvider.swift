import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// #2438 Phase 3a(AFM-12):Apple Foundation Models 逐字稿校正後端。提示詞沿 `CorrectionPrompt`(只含段號＋原文),
/// 子批 ≤ `AFMBudget.correctionBatchMax`;回來的建議照常交給 `CorrectionRules.validate`(original 必須逐字命中)。
@available(macOS 26, *)
public struct AppleFMCorrectionProvider: CorrectionProvider {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 120) { self.timeout = timeout }

    @Generable
    struct CorrectionDraft {
        @Guide(description: "最可能聽錯的詞與修正;沒有就空陣列", .maximumCount(20)) var corrections: [CorrectionItem]
    }

    @Generable
    struct CorrectionItem {
        @Guide(description: "段號") var segment: Int
        @Guide(description: "該段原文中逐字出現的字串") var original: String
        @Guide(description: "修正後的字串") var suggestion: String
        @Guide(description: "一句理由") var reason: String
    }

    public func suggest(segments: [String], range: Range<Int>, language: TranscriptionLanguage) async throws -> CorrectionResult {
        let started = Date()
        let instructions = CorrectionPrompt.system(for: language)
        var out: [CorrectionSuggestion] = []
        var inTokens = 0, outTokens = 0
        for sub in AFMBudget.correctionBatches(segments: segments, range: range) {
            let user = CorrectionPrompt.user(segments: segments, range: sub, language: language)
            inTokens += AFMBudget.estimateTokens(instructions) + AFMBudget.estimateTokens(user)
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: AFMBudget.correctionOutputMax)
            do {
                let draft = try await AFMCorrectionTimeout.run(seconds: timeout) {
                    try await session.respond(to: user, generating: CorrectionDraft.self, options: options).content
                }
                for item in draft.corrections {
                    out.append(CorrectionSuggestion(segment: item.segment, original: item.original,
                                                    suggestion: item.suggestion, reason: item.reason))
                    outTokens += AFMBudget.estimateTokens(item.original + item.suggestion + item.reason) + 4
                }
            } catch let e as LanguageModelSession.GenerationError {
                if AFMErrors.isGuardrail(e) { continue }          // 這一批跳過,其他照常
                if AFMErrors.isContextOverflow(e) { throw CorrectionError.failed(-1, "段落太長") }
                if AFMErrors.isUnsupportedLanguage(e) { throw CorrectionError.failed(-2, "不支援的語言") }
                throw CorrectionError.failed(-2, String(String(describing: e).prefix(120)))
            } catch let e as CorrectionError {
                throw e
            } catch {
                if AFMErrors.describesGuardrail(error) { continue }
                if AFMErrors.describesContextOverflow(error) { throw CorrectionError.failed(-1, "段落太長") }
                throw CorrectionError.failed(-2, String(String(describing: error).prefix(120)))
            }
        }
        return CorrectionResult(suggestions: out, inputTokens: inTokens, outputTokens: outTokens,
                                durationMs: Int(Date().timeIntervalSince(started) * 1000))
    }
}

@available(macOS 26, *)
enum AFMCorrectionTimeout {
    struct TimedOut: Error {}
    static func run<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimedOut() }
            do { let v = try await group.next()!; group.cancelAll(); return v }
            catch is TimedOut { group.cancelAll(); throw CorrectionError.timeout }
        }
    }
}
#endif
