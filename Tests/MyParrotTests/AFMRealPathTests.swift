import Testing
import Foundation
@testable import MyParrotCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// #2438 Phase 3a AFM-07/05/12 真路徑(鐵則 3):真的叫 Apple Foundation Models。預設關,`MP_AFM_REAL=1` 才跑
/// (要 macOS 26+、Apple Intelligence 可用)。合成逐字稿在這裡生,不含任何真資料。
@Suite("AFM 真路徑(MP_AFM_REAL=1 才跑)")
struct AFMRealPathTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MP_AFM_REAL"] == "1" }

    /// 60 行合成週會:你／對方交替,講一個虛構的產品會議。
    static func syntheticLines(_ n: Int) -> [String] {
        let topics = ["淺色遙控器改成銀色,下週三前完成", "外觀設定加三選一,跟隨系統是預設", "首次啟動要有說明框告訴使用者去哪開模型",
                      "會議記錄後端先接本機模型,資料不出機", "校正層要能抓語音辨識聽錯的詞", "發版前要重拍四張截圖",
                      "系統需求寫 macOS 15 以上", "隱私聲明要講清楚哪些功能會連網", "Eric 負責驗收,週五回報",
                      "下一版版號定 0.5", "測試矩陣要跑新舊兩個版本", "錄音中不能重裝 app"]
        return (0..<n).map { i in
            let who = i % 2 == 0 ? "對方" : "你"
            let t = i * 9
            return "\(who) \(t / 3600):\(String(format: "%02d", (t % 3600) / 60)):\(String(format: "%02d", t % 60)): \(topics[i % topics.count])(第 \(i + 1) 句)"
        }
    }

    @Test("AFM-07 滾動兩輪(30＋30 行)", .enabled(if: enabled))
    func rollingTwoRounds() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let p = AppleFMMinutesProvider(timeout: 300)   // 量真實耗時;產品預設 120 秒,數字進報告
        let lines = Self.syntheticLines(60)
        var t0 = Date()
        let r1 = try await p.update(MinutesInput(previous: nil, transcriptDelta: Array(lines[0..<30]), notes: "# 合成週會\n- 重點:銀色遙控器", language: .system))
        let ms1 = Int(Date().timeIntervalSince(t0) * 1000)
        #expect(!r1.summary.isEmpty && r1.summary.count <= 400)
        #expect(!(r1.decisions.isEmpty && r1.actions.isEmpty && r1.timeline.isEmpty))
        t0 = Date()
        var prev = r1; prev.transcriptLinesConsumed = 30
        let r2 = try await p.update(MinutesInput(previous: prev, transcriptDelta: Array(lines[30..<60]), notes: "# 合成週會\n- 重點:銀色遙控器\n- 版號 0.5", language: .system))
        let ms2 = Int(Date().timeIntervalSince(t0) * 1000)
        #expect(!r2.summary.isEmpty)
        #expect(r2.transcriptLinesConsumed == 30)
        print("AFM-REAL rolling: round1 \(ms1) ms in≈\(r1.inputTokens) out≈\(r1.outputTokens) | round2 \(ms2) ms in≈\(r2.inputTokens) out≈\(r2.outputTokens) | timeline \(r1.timeline.count)→\(r2.timeline.count) decisions \(r2.decisions.count) actions \(r2.actions.count)")
        #endif
    }

    @Test("AFM-05 超大段退讓後成功", .enabled(if: enabled))
    func contextRetry() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let p = AppleFMMinutesProvider(timeout: 300, chunkMax: 4500)   // 故意超過 4096,逼框架丟超出上下文
        let lines = Self.syntheticLines(200)
        let t0 = Date()
        let r = try await p.update(MinutesInput(previous: nil, transcriptDelta: lines, notes: "", language: .system))
        print("AFM-REAL retry: \(Int(Date().timeIntervalSince(t0) * 1000)) ms, summary \(r.summary.count) chars, in≈\(r.inputTokens)")
        #expect(!r.summary.isEmpty)
        #endif
    }

    @Test("AFM-12 校正品質閘(10 個聽錯詞)", .enabled(if: enabled))
    func correctionQualityGate() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let planted: [(wrong: String, right: String)] = [("竹子稿", "逐字稿"), ("會議基路", "會議紀錄"), ("麥克封", "麥克風"), ("藍牙耳雞", "藍牙耳機"),
                                                         ("系統因訊", "系統音訊"), ("逐字搞", "逐字稿"), ("錄因", "錄音"), ("暫亭", "暫停"), ("結蜀", "結束"), ("標技", "標記")]
        var segments: [String] = []
        for i in 0..<20 {
            if i % 2 == 0 {
                let p = planted[i / 2]
                segments.append("我們把這段\(p.wrong)整理一下,下週再看一次")
            } else {
                segments.append("好,那這個部分我會先記下來,等一下再討論")
            }
        }
        let provider = AppleFMCorrectionProvider(timeout: 300)
        let t0 = Date()
        let r = try await provider.suggest(segments: segments, range: 0..<segments.count, language: .system)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let valid = CorrectionRules.validate(r.suggestions, segments: segments, range: 0..<segments.count)
        let invalid = r.suggestions.count - valid.count
        let hits = planted.filter { pl in valid.contains { $0.original.contains(pl.wrong) } }.count
        let exact = planted.filter { pl in valid.contains { $0.original.contains(pl.wrong) && $0.suggestion.contains(pl.right) } }.count
        print("AFM-REAL correction: \(ms) ms raw \(r.suggestions.count) valid \(valid.count) invalid \(invalid) hits \(hits)/10 exact \(exact)/10 in≈\(r.inputTokens) out≈\(r.outputTokens)")
        for s in valid { print("  seg \(s.segment): \(s.original) → \(s.suggestion) (\(s.reason))") }
        #expect(invalid == 0)
        #expect(hits >= 5, "品質閘:至少抓到 5/10,得 \(hits)")
        #endif
    }
}
