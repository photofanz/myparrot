import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// #2438 Phase 3a(AFM-03/04/05):Apple Foundation Models 會議記錄後端。資料全部留在本機。
/// 每次更新新開 `LanguageModelSession`(不累積歷史);使用者訊息沿 `MinutesPrompt.user` 三段格式,
/// 與 Claude CLI 後端一字不差;增量照 `AFMBudget.chunk` 切段、段與段 previous 接力;
/// `exceededContextWindowSize` ⇒ 對半重試最多 3 次;`guardrailViolation` ⇒ 跳過該段不讓整輪失敗。
/// token 數是估算(框架不回 usage)。
@available(macOS 26, *)
public struct AppleFMMinutesProvider: MinutesProvider {
    public var timeout: TimeInterval
    public var chunkMax: Int

    public init(timeout: TimeInterval = 120, chunkMax: Int = AFMBudget.deltaChunkMax) {
        self.timeout = timeout
        self.chunkMax = chunkMax
    }

    @Generable
    struct MinutesDraft {
        @Guide(description: "會議摘要,最多 300 字") var summary: String
        @Guide(description: "決議事項,每條一句", .maximumCount(12)) var decisions: [String]
        @Guide(description: "待辦事項,每條一句(含負責人若有)", .maximumCount(12)) var actions: [String]
        @Guide(description: "待釐清問題,每條一句", .maximumCount(12)) var questions: [String]
        @Guide(description: "時間軸,每條「h:mm:ss 事件」", .maximumCount(20)) var timeline: [String]
    }

    public func update(_ input: MinutesInput) async throws -> MinutesDocument {
        let instructions = MinutesPrompt.system(for: input.language)
        var previous = input.previous.map { AFMBudget.compressPrevious($0) }
        let notes = AFMBudget.notesTail(input.notes)
        let chunks = AFMBudget.chunk(lines: input.transcriptDelta, max: chunkMax)
        var inTokens = 0, outTokens = 0, skipped = 0
        var produced: MinutesDraft? = nil
        let work: [[String]] = chunks.isEmpty ? [[]] : chunks
        for chunk in work {
            var attempt = 1
            var pieces: [[String]] = [chunk]
            var done = false
            while !done {
                var okAll = true
                for piece in pieces {
                    let user = MinutesPrompt.user(MinutesInput(previous: previous, transcriptDelta: piece, notes: notes, language: input.language))
                    inTokens += AFMBudget.estimateTokens(instructions) + AFMBudget.estimateTokens(user)
                    do {
                        let draft = try await respond(instructions: instructions, user: user)
                        outTokens += AFMBudget.estimateTokens(Self.draftJSON(draft))
                        produced = draft
                        previous = Self.document(from: draft, previous: input.previous, now: Date())
                    } catch let e as LanguageModelSession.GenerationError {
                        if AFMErrors.isContextOverflow(e) {
                            // AFM-05:對半再試,最多 3 次(10/20 真跑:框架的 case 名比對不到,改看描述當後備)。
                            attempt += 1
                            guard let n = AFMBudget.halvePlan(attempt: attempt) else { throw MinutesError.failed(-1, "段落太長") }
                            pieces = AFMBudget.split(chunk, into: n)
                            okAll = false
                        } else if AFMErrors.isGuardrail(e) {
                            skipped += 1
                        } else if AFMErrors.isUnsupportedLanguage(e) {
                            throw MinutesError.failed(-2, "不支援的語言")
                        } else {
                            throw MinutesError.failed(-2, Self.oneLine(e))
                        }
                    } catch let e as MinutesError {
                        throw e
                    } catch {
                        // 10/20 真跑:超出上下文的錯誤不是 GenerationError 型別(描述「Content contains N tokens, which exceeds
                        // the maximum allowed context size of 4096.」),只能看描述。
                        if AFMErrors.describesContextOverflow(error) {
                            attempt += 1
                            guard let n = AFMBudget.halvePlan(attempt: attempt) else { throw MinutesError.failed(-1, "段落太長") }
                            pieces = AFMBudget.split(chunk, into: n)
                            okAll = false
                        } else if AFMErrors.describesGuardrail(error) {
                            skipped += 1
                        } else {
                            throw MinutesError.failed(-2, Self.oneLine(error))
                        }
                    }
                    if !okAll { break }
                }
                done = okAll
            }
        }
        guard let draft = produced else {
            if skipped > 0 { throw MinutesError.badOutput("安全守則拒絕了全部段落") }
            throw MinutesError.badOutput("沒有產出")
        }
        var doc = Self.document(from: draft, previous: input.previous, now: Date())
        doc.inputTokens = inTokens
        doc.outputTokens = outTokens
        return doc
    }

    private func respond(instructions: String, user: String) async throws -> MinutesDraft {
        let session = LanguageModelSession(instructions: instructions)
        // 10/20 真跑:預設取樣品質起伏大(校正閘 8/10 → 0/10),改 greedy 求可重現。
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: AFMBudget.outputMax)
        return try await AFMTimeout.run(seconds: timeout) {
            try await session.respond(to: user, generating: MinutesDraft.self, options: options).content
        }
    }

    static func document(from d: MinutesDraft, previous: MinutesDocument?, now: Date) -> MinutesDocument {
        MinutesDocument(summary: d.summary, decisions: d.decisions, actions: d.actions, questions: d.questions,
                        timeline: d.timeline, updatedAt: now, inputTokens: 0, outputTokens: 0,
                        transcriptLinesConsumed: previous?.transcriptLinesConsumed ?? 0)
    }

    static func draftJSON(_ d: MinutesDraft) -> String {
        MinutesPrompt.previousJSON(MinutesDocument(summary: d.summary, decisions: d.decisions, actions: d.actions,
                                                   questions: d.questions, timeline: d.timeline)) ?? ""
    }

    static func oneLine(_ e: Error) -> String {
        String(String(describing: e).split(separator: "\n").first ?? "").prefix(120).description
    }
}

/// 框架錯誤分類:先比 case,比不到就看描述(10/20 真跑發現 `exceededContextWindowSize` 的 case 比對不中,
/// 描述是「Content contains N tokens, which exceeds the maximum allowed context size of 4096.」)。
@available(macOS 26, *)
enum AFMErrors {
    static func isContextOverflow(_ e: LanguageModelSession.GenerationError) -> Bool {
        if case .exceededContextWindowSize = e { return true }
        let d = String(describing: e).lowercased()
        return d.contains("context") && (d.contains("exceed") || d.contains("window") || d.contains("size"))
    }
    static func isGuardrail(_ e: LanguageModelSession.GenerationError) -> Bool {
        if case .guardrailViolation = e { return true }
        return String(describing: e).lowercased().contains("guardrail")
    }
    static func isUnsupportedLanguage(_ e: LanguageModelSession.GenerationError) -> Bool {
        if case .unsupportedLanguageOrLocale = e { return true }
        return String(describing: e).lowercased().contains("unsupportedlanguage")
    }
    /// 任意 Error 的描述判定(非 GenerationError 型別時用)。
    static func describesContextOverflow(_ e: Error) -> Bool {
        let d = (String(describing: e) + " " + e.localizedDescription).lowercased()
        return d.contains("context") && (d.contains("exceed") || d.contains("window") || d.contains("size"))
    }
    static func describesGuardrail(_ e: Error) -> Bool {
        (String(describing: e) + " " + e.localizedDescription).lowercased().contains("guardrail")
    }
}

/// 逾時:跟模型回應賽跑,逾時就取消並丟 `MinutesError.timeout`。
@available(macOS 26, *)
enum AFMTimeout {
    struct TimedOut: Error {}
    static func run<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            do {
                let v = try await group.next()!
                group.cancelAll()
                return v
            } catch is TimedOut {
                group.cancelAll()
                throw MinutesError.timeout
            }
        }
    }
}
#endif
