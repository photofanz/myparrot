import Foundation

/// #2438 Phase 3a(AFM-02/04/05)的純函式案例:登錄表平台守門、token 估算、切段、壓縮、取尾、退讓、訊息對照、校正子批。
extension SelfTest {

    static func afmRegistry() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        let ids = { (list: [ModelBackendInfo]) in list.map(\.id) }
        let with = R.assemble(platformSupportsAFM: true), without = R.assemble(platformSupportsAFM: false)
        if !ids(with).contains("appleFM") { fails.append("支援平台應列 appleFM") }
        if ids(without).contains("appleFM") { fails.append("不支援平台不應列 appleFM") }
        if ids(with).firstIndex(of: "appleFM") != 2 { fails.append("appleFM 應排在 claudeCLI 之後,得 \(ids(with))") }
        if R.appleFM.capabilities != [.correction, .minutes] || !R.appleFM.isLocal || R.appleFM.debugOnly { fails.append("appleFM 宣告不對") }
        if R.appleFM.id != CorrectionBackend.appleFM.rawValue { fails.append("appleFM id 應等於 CorrectionBackend.appleFM.rawValue") }
        if R.needsPrivacyConfirmation("appleFM", defaults: UserDefaults(suiteName: "MyParrotSelfTest.afm")!) { fails.append("本機後端不該跳隱私框") }
        if ids(R.filter(with, for: .translation, includeDebugOnly: true)).contains("appleFM") { fails.append("appleFM 不支援翻譯") }
        return Result(name: "AFM-02 登錄表平台守門", passed: fails.isEmpty, detail: fails.isEmpty ? "with/without 兩種平台皆符" : fails.joined(separator: "; "))
    }

    static func afmTokenEstimate() -> Result {
        var fails: [String] = []
        let B = AFMBudget.self
        if B.estimateTokens("你好世界") != 6 { fails.append("CJK 4 字應 6(1.5/字),得 \(B.estimateTokens("你好世界"))") }
        if B.estimateTokens("你") != 2 { fails.append("CJK 1 字應向上取整成 2,得 \(B.estimateTokens("你"))") }
        if B.estimateTokens("hello world") != 3 { fails.append("11 個拉丁字元應 3,得 \(B.estimateTokens("hello world"))") }
        if B.estimateTokens("a\nb") != 2 { fails.append("a\\nb 應 2(1 換行＋2 字元→1),得 \(B.estimateTokens("a\nb"))") }
        if B.estimateTokens("逐字稿 ok") != 6 { fails.append("混合應 3 CJK(5)＋1(3 字元),得 \(B.estimateTokens("逐字稿 ok"))") }
        if B.estimateTokens("") != 0 { fails.append("空字串應 0") }
        return Result(name: "AFM-04 token 估算", passed: fails.isEmpty, detail: fails.isEmpty ? "CJK 1.5/字、拉丁 4 單位/1、換行 1、混合命中" : fails.joined(separator: "; "))
    }

    static func afmChunk() -> Result {
        var fails: [String] = []
        let line = String(repeating: "會", count: 30)            // 45 token
        let lines = (0..<120).map { "\($0 % 10)" + line }        // 每行 46 token＋1 換行
        let chunks = AFMBudget.chunk(lines: lines, max: 1400)
        if chunks.flatMap({ $0 }) != lines { fails.append("拼回應等於原文") }
        for (i, c) in chunks.enumerated() {
            let t = c.reduce(0) { $0 + AFMBudget.estimateTokens($1) + 1 }
            if t > 1400 { fails.append("第 \(i) 段 \(t) tokens 超過 1400") }
        }
        if chunks.count < 4 { fails.append("120 行×47 應至少 4 段,得 \(chunks.count)") }
        let long = String(repeating: "長", count: 3000)
        let hard = AFMBudget.chunk(lines: [long], max: 1400)
        if hard.count < 3 || hard.contains(where: { $0.count != 1 }) { fails.append("3000 字單行應硬切成 ≥3 片,得 \(hard.count)") }
        if hard.flatMap({ $0 }).joined() != long { fails.append("硬切拼回應等於原行") }
        if !AFMBudget.chunk(lines: []).isEmpty { fails.append("空輸入應回空") }
        let split = AFMBudget.split(Array(lines.prefix(10)), into: 4)
        if split.count != 4 || split.flatMap({ $0 }) != Array(lines.prefix(10)) { fails.append("split 10 行成 4 份應 3/3/3/1 且拼回相等,得 \(split.map(\.count))") }
        return Result(name: "AFM-04 增量切段", passed: fails.isEmpty, detail: fails.isEmpty ? "\(chunks.count) 段、硬切 \(hard.count) 片" : fails.joined(separator: "; "))
    }

    static func afmCompressPrevious() -> Result {
        var fails: [String] = []
        let big = MinutesDocument(summary: String(repeating: "摘", count: 500),
                                  decisions: (0..<40).map { "決議第\($0)條" + String(repeating: "字", count: 20) },
                                  actions: (0..<40).map { "待辦第\($0)條" + String(repeating: "字", count: 20) },
                                  questions: (0..<10).map { "問題\($0)" }, timeline: (0..<20).map { "0:0\($0 % 10):00 事件\($0)" })
        let c = AFMBudget.compressPrevious(big, max: 700)
        let size = AFMBudget.estimateTokens(MinutesPrompt.previousJSON(c) ?? "")
        if size > 700 { fails.append("壓縮後 \(size) > 700") }
        if c.summary.count != 300 { fails.append("摘要應截 300,得 \(c.summary.count)") }
        if c.decisions.last != big.decisions.last || c.actions.last != big.actions.last { fails.append("應保留最後幾條(從最舊丟)") }
        if c.timeline.count != 20 && (c.decisions.count + c.actions.count + c.questions.count) > 0 { fails.append("時間軸應最後才丟") }
        let small = MinutesDocument(summary: "短", decisions: ["a"], actions: [], questions: [], timeline: ["0:00:01 x"])
        if AFMBudget.compressPrevious(small) != small { fails.append("已在預算內不該動") }
        return Result(name: "AFM-04 上一版壓縮", passed: fails.isEmpty, detail: fails.isEmpty ? "壓到 \(size) tokens、摘要 300 字、保留尾端" : fails.joined(separator: "; "))
    }

    static func afmNotesTail() -> Result {
        var fails: [String] = []
        let lines = ["# 標題"] + (0..<200).map { "- 第\($0)行" + String(repeating: "筆", count: 10) }
        let notes = lines.joined(separator: "\n")
        let tail = AFMBudget.notesTail(notes, max: 400)
        if !tail.hasPrefix("# 標題\n") { fails.append("標題應保留") }
        if AFMBudget.estimateTokens(tail) > 400 { fails.append("取尾後 \(AFMBudget.estimateTokens(tail)) > 400") }
        if !tail.hasSuffix(lines.last!) { fails.append("應保留最後一行") }
        if AFMBudget.notesTail("# 短\n- 一", max: 400) != "# 短\n- 一" { fails.append("在預算內不該動") }
        return Result(name: "AFM-04 筆記取尾", passed: fails.isEmpty, detail: fails.isEmpty ? "標題保留、尾段在預算內" : fails.joined(separator: "; "))
    }

    static func afmHalvePlan() -> Result {
        let got = [1, 2, 3, 4, 5].map { AFMBudget.halvePlan(attempt: $0) }
        let want: [Int?] = [1, 2, 4, nil, nil]
        let ok = got == want
        return Result(name: "AFM-05 退讓計畫", passed: ok, detail: ok ? "1→1, 2→2, 3→4, 4→nil" : "得 \(got)")
    }

    static func afmMessageMap() -> Result {
        var fails: [String] = []
        if AFMAvailability.messageKey(for: .available) != nil { fails.append("available 應 nil") }
        let states: [AFMStatus] = [.unsupportedOS] + AFMReason.allCases.map { .unavailable($0) }
        var seen = Set<String>()
        for s in states {
            guard let k = AFMAvailability.messageKey(for: s), !k.isEmpty else { fails.append("\(s) 應有 key"); continue }
            if !seen.insert(k).inserted { fails.append("\(s) 的 key 重複") }
        }
        if !(AFMAvailability.messageKey(for: .unavailable(.modelNotReady)) ?? "").contains("Siri") { fails.append("modelNotReady 要提 Siri 語言(10/20 根因)") }
        return Result(name: "AFM-01 狀態→訊息", passed: fails.isEmpty, detail: fails.isEmpty ? "5 個狀態各有獨立 key" : fails.joined(separator: "; "))
    }

    static func afmCorrectionBatches() -> Result {
        var fails: [String] = []
        let seg = (0..<50).map { "第\($0)段" + String(repeating: "字", count: 100) }   // 每段約 104 token
        let b = AFMBudget.correctionBatches(segments: seg, range: 5..<45, max: 1200)
        if b.first?.lowerBound != 5 || b.last?.upperBound != 45 { fails.append("範圍頭尾應 5..<45,得 \(b)") }
        for r in b {
            let t = r.reduce(0) { $0 + AFMBudget.estimateTokens("\($1): \(seg[$1])") + 1 }
            if t > 1200 { fails.append("子批 \(r) \(t) > 1200") }
        }
        var cover: [Int] = []; for r in b { cover += Array(r) }
        if cover != Array(5..<45) { fails.append("子批應剛好覆蓋 range 一次") }
        let huge = [String(repeating: "大", count: 5000)]
        if AFMBudget.correctionBatches(segments: huge, range: 0..<1) != [0..<1] { fails.append("單段超過上限應自成一批") }
        return Result(name: "AFM-12 校正子批", passed: fails.isEmpty, detail: fails.isEmpty ? "\(b.count) 批、覆蓋完整" : fails.joined(separator: "; "))
    }
}
