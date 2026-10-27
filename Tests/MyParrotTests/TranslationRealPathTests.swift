import Testing
import Foundation
@testable import MyParrotCore

/// #2612 TRL-11 真路徑(鐵則 3):真的 spawn 本機 `claude`／`codex` 各翻一批(吃 Eric 的訂閱額度)。預設關,`MP_CLI_REAL=1` 才跑。
/// 合成英文會議稿在這裡生,不含任何真資料;每批 tokens／毫秒印出來給 TEST_REPORT 抄。
@Suite("翻譯真路徑(MP_CLI_REAL=1 才跑)")
struct TranslationRealPathTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MP_CLI_REAL"] == "1" }

    static let lines = ["Let's start with the budget review for next quarter.",
                        "The vendor sent a revised quote yesterday, about twelve percent lower.",
                        "We still need legal to sign off on the data-processing clause.",
                        "Can your team deliver the onboarding flow by the end of November?",
                        "That depends on whether the API freeze holds.",
                        "I'd rather ship a smaller scope than slip the date again.",
                        "Agreed. Let's cut the analytics dashboard from this release.",
                        "Who owns the follow-up with the Singapore office?",
                        "I'll take it and report back on Friday.",
                        "One more thing: the security audit findings are due Monday."]

    @Test("TRL-11 Claude CLI 翻一批 10 行", .enabled(if: enabled))
    func claude() async throws {
        let exe = try #require(ClaudeCLIProvider.locate(), "找不到 claude")
        let p = ClaudeCLITranslationProvider(executable: exe, model: nil, timeout: 120, target: .zhHant)
        let t0 = Date()
        let r = try await p.translate(Self.lines, from: Locale.Language(identifier: "en-US"), to: TranslationTarget.zhHant.language)
        print("TRL-REAL claude: \(Int(Date().timeIntervalSince(t0) * 1000)) ms in=\(r.inputTokens) out=\(r.outputTokens) lines=\(r.lines.count)")
        for (i, l) in r.lines.enumerated() { print("  \(i + 1) \(l)") }
        #expect(r.lines.count == Self.lines.count)
        #expect(r.lines.allSatisfy { !$0.isEmpty && !$0.hasPrefix("1:") })
        #expect(r.inputTokens > 1000 && r.outputTokens > 0)
    }

    @Test("TRL-11 Codex CLI 翻一批 10 行", .enabled(if: enabled))
    func codex() async throws {
        let exe = try #require(CodexCLIProvider.locate(), "找不到 codex")
        let p = CodexCLITranslationProvider(executable: exe, model: nil, timeout: 120, target: .zhHant)
        let t0 = Date()
        let r = try await p.translate(Self.lines, from: Locale.Language(identifier: "en-US"), to: TranslationTarget.zhHant.language)
        print("TRL-REAL codex: \(Int(Date().timeIntervalSince(t0) * 1000)) ms in=\(r.inputTokens) out=\(r.outputTokens) lines=\(r.lines.count)")
        for (i, l) in r.lines.enumerated() { print("  \(i + 1) \(l)") }
        #expect(r.lines.count == Self.lines.count)
        #expect(r.lines.allSatisfy { !$0.isEmpty })
        #expect(r.inputTokens > 1000 && r.outputTokens > 0)
    }
}
