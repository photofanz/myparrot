import Testing
import Foundation
@testable import MyParrotCore

/// #2418 CDX-04／11 真路徑(鐵則 3):真的 spawn 本機 `codex`(吃 Eric 的 ChatGPT 額度)。預設關,`MP_CODEX_REAL=1` 才跑
/// (要已安裝＋已登入)。合成逐字稿在這裡生,不含任何真資料;每次呼叫把 tokens／毫秒印出來給 TEST_REPORT 抄。
@Suite("Codex 真路徑(MP_CODEX_REAL=1 才跑)")
struct CodexRealPathTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MP_CODEX_REAL"] == "1" }

    /// 6 段合成會議逐字稿,埋 3 個同音聽錯:台積店(台積電)、竹子稿(逐字稿)、藍芽(藍牙);其餘正確(「兩百萬」「下週三」不該被改)。
    static let segments = ["我們明天去台積店開會,預算兩百萬",
                           "會議的竹子稿要在下週三前整理好",
                           "藍芽耳機切換的問題這一版已經修掉",
                           "首次啟動的提示框要講清楚去哪裡開模型",
                           "發版前要重拍四張截圖",
                           "系統需求寫 macOS 26 以上"]

    static func syntheticLines(_ n: Int) -> [String] {
        let topics = ["淺色遙控器改成銀色,下週三前完成", "外觀設定加三選一,跟隨系統是預設", "首次啟動要有說明框告訴使用者去哪開模型",
                      "會議記錄後端多接一個 Codex CLI", "校正層要能抓語音辨識聽錯的詞", "發版前要重拍四張截圖",
                      "系統需求寫 macOS 26 以上", "隱私聲明要講清楚哪些功能會連網", "Eric 負責驗收,週五回報",
                      "下一版版號定 0.5.2", "測試矩陣要跑新舊兩個版本", "錄音中不能重裝 app"]
        return (0..<n).map { i in
            let who = i % 2 == 0 ? "對方" : "你"
            let t = i * 9
            return "\(who) \(t / 3600):\(String(format: "%02d", (t % 3600) / 60)):\(String(format: "%02d", t % 60)): \(topics[i % topics.count])(第 \(i + 1) 句)"
        }
    }

    @Test("CDX-04/11 校正:6 段 3 個埋雷,真 codex", .enabled(if: enabled))
    func realCorrection() async throws {
        let exe = try #require(CodexCLIProvider.locate(), "找不到 codex")
        #expect(await CodexCLIProvider.isLoggedIn(executable: exe), "codex login status 應為已登入")
        let provider = CodexCLIProvider(executable: exe, model: nil, timeout: 120)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        let r = try await provider.suggest(segments: Self.segments, range: 0..<Self.segments.count, language: .zhTW)
        let valid = CorrectionRules.validate(r.suggestions, segments: Self.segments, range: 0..<Self.segments.count)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        let leftover = after.subtracting(before).filter { $0.hasPrefix("myparrot-codex-") }
        #expect(leftover.isEmpty, "暫存夾應呼叫後即刪,殘留 \(leftover)")
        let hits = valid.map(\.suggestion)
        print("CODEX-REAL correction: \(r.durationMs) ms in=\(r.inputTokens) out=\(r.outputTokens) raw=\(r.suggestions.count) valid=\(valid.count) " +
              "hits=\(hits) touchedCorrect=\(valid.filter { $0.original.contains("兩百萬") || $0.original.contains("下週三") }.count)")
        #expect(valid.count >= 2, "三個埋雷至少抓兩個,得 \(hits)")
        #expect(!valid.contains { $0.original.contains("兩百萬") }, "正確的「兩百萬」不該被改")
        #expect(r.inputTokens > 1000 && r.outputTokens > 0, "usage 要從 turn.completed 讀到")
    }

    @Test("CDX-04/11 會議記錄:30 行＋筆記,真 codex", .enabled(if: enabled))
    func realMinutes() async throws {
        let exe = try #require(CodexCLIProvider.locate(), "找不到 codex")
        let p = CodexCLIMinutesProvider(executable: exe, model: nil, timeout: 180)
        let lines = Self.syntheticLines(30)
        let t0 = Date()
        let r = try await p.update(MinutesInput(previous: nil, transcriptDelta: lines, notes: "# 合成週會\n- 重點:Codex 後端", language: .zhTW))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("CODEX-REAL minutes: \(ms) ms in=\(r.inputTokens) out=\(r.outputTokens) summary=\(r.summary.count) chars decisions=\(r.decisions.count) actions=\(r.actions.count) questions=\(r.questions.count) timeline=\(r.timeline.count)")
        #expect(!r.summary.isEmpty && r.summary.count <= 400)
        #expect(!(r.decisions.isEmpty && r.actions.isEmpty && r.timeline.isEmpty))
        #expect(r.timeline.allSatisfy { $0.contains(":") }, "時間軸每項應帶 h:mm:ss")
        #expect(r.inputTokens > 1000 && r.outputTokens > 0)
    }
}
