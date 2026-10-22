import Foundation

/// #2483 C 的純函式案例:校正重套、持久化往返。
extension SelfTest {
    static func transcriptHandoffReapply() -> Result {
        var fails: [String] = []
        func line(_ t: TimeInterval, _ s: String) -> TranscriptLine {
            TranscriptLine(isYou: false, time: Date(timeIntervalSince1970: t), text: s, isFinal: true, start: t)
        }
        let lines = [line(5, "我們把竹子稿整理一下"), line(60, "竹子稿再看一次"), line(120, "麥克封壞了")]
        let acc = [AcceptedCorrection(original: "竹子稿", suggestion: "逐字稿", reason: "", at: 62),
                   AcceptedCorrection(original: "麥克封", suggestion: "麥克風", reason: "", at: 500),
                   AcceptedCorrection(original: "不存在的詞", suggestion: "x", reason: "", at: 5)]
        let r = TranscriptHandoff.reapply(acc, to: lines)
        if r.lines[1].text != "逐字稿再看一次" { fails.append("應先套 ±10 秒內那行(60s),得 \(r.lines[1].text)") }
        if r.lines[0].text != "我們把竹子稿整理一下" { fails.append("第一行不在窗內且已有命中,不該被改") }
        if r.lines[2].text != "麥克風壞了" { fails.append("窗外找不到時應全文找第一個,得 \(r.lines[2].text)") }
        if r.unmatched != 1 { fails.append("找不到的應算 1 則,得 \(r.unmatched)") }
        let twice = TranscriptHandoff.reapply([acc[0]], to: [line(0, "竹子稿竹子稿")])
        if twice.lines[0].text != "逐字稿竹子稿" { fails.append("一行只換第一次出現,得 \(twice.lines[0].text)") }
        return Result(name: "TRX-03 校正重套", passed: fails.isEmpty, detail: fails.isEmpty ? "窗內優先、全文後備、一行一次、未命中計數" : fails.joined(separator: "; "))
    }

    static func transcriptHandoffPersist() -> Result {
        var fails: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-selftest-handoff-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("2026-10-20 1200 合成")
        if !TranscriptHandoff.load(stem: stem).isEmpty { fails.append("空的應回 []") }
        TranscriptHandoff.append(AcceptedCorrection(original: "a", suggestion: "b", reason: "r", at: 1), stem: stem)
        TranscriptHandoff.append(AcceptedCorrection(original: "c", suggestion: "d", reason: "r", at: 2), stem: stem)
        TranscriptHandoff.append(AcceptedCorrection(original: "a", suggestion: "b", reason: "r", at: 1.2), stem: stem)   // 同則重複不累積
        if TranscriptHandoff.load(stem: stem).count != 2 { fails.append("應 2 則(重複不累積),得 \(TranscriptHandoff.load(stem: stem).count)") }
        if TranscriptHandoff.correctionsURL(stem: stem).lastPathComponent != "2026-10-20 1200 合成.corrections.json" { fails.append("檔名應 <stem>.corrections.json") }
        if TranscriptHandoff.liveURL(stem: stem).lastPathComponent != "2026-10-20 1200 合成.live.srt" { fails.append("檔名應 <stem>.live.srt") }
        TranscriptHandoff.remove(original: "a", suggestion: "b", stem: stem)
        if TranscriptHandoff.load(stem: stem).map(\.original) != ["c"] { fails.append("移除後應剩 c") }
        TranscriptHandoff.remove(original: "c", suggestion: "d", stem: stem)
        if FileManager.default.fileExists(atPath: TranscriptHandoff.correctionsURL(stem: stem).path) { fails.append("清空後檔案應刪除") }
        if !SidecarSet.extensions.contains("corrections.json") || !SidecarSet.extensions.contains("live.srt") { fails.append("SidecarSet.extensions 要含兩個新 sidecar(改名／垃圾桶一起帶)") }
        return Result(name: "TRX-03 校正紀錄持久化", passed: fails.isEmpty, detail: fails.isEmpty ? "append/load/remove 往返、檔名、sidecar 清單" : fails.joined(separator: "; "))
    }

    static func transcribePolicyMigration() -> Result {
        var fails: [String] = []
        let P = TranscribePolicy.self
        if P.migrate(raw: nil, legacy: nil) != .whenIdle { fails.append("都沒設應 whenIdle") }
        if P.migrate(raw: nil, legacy: true) != .whenIdle { fails.append("舊 true 應 whenIdle") }
        if P.migrate(raw: nil, legacy: false) != .never { fails.append("舊 false 應 never") }
        if P.migrate(raw: "immediately", legacy: false) != .immediately { fails.append("新鍵優先") }
        if P.migrate(raw: "bogus", legacy: true) != .whenIdle { fails.append("新鍵怪值 ⇒ 看舊布林") }
        return Result(name: "TRX-05 重轉政策遷移", passed: fails.isEmpty, detail: fails.isEmpty ? "5 組對照" : fails.joined(separator: "; "))
    }

    static func idleTranscribeDecision() -> Result {
        var fails: [String] = []
        let f = IdleTranscribePolicy.shouldRun
        if !f(.finished, false, true, 200, 1) { fails.append("條件齊應 true") }
        if f(.finished, false, true, 200, 0) { fails.append("沒待轉應 false") }
        if f(.recording, false, true, 200, 1) || f(.paused, false, true, 200, 1) { fails.append("錄音／暫停中應 false") }
        if f(.finished, true, true, 200, 1) { fails.append("轉稿中應 false") }
        if f(.finished, false, false, 200, 1) { fails.append("沒接電應 false") }
        if f(.finished, false, true, 119, 1) { fails.append("閒置 119 秒應 false") }
        if !f(.idle, false, true, 120, 2) { fails.append("閒置剛好 120 秒應 true") }
        if RecordingController.canUnloadWhisperWithPending(isTranscribing: false, queuedCount: 0, state: .idle, liveTranscribeEnabled: true, pendingCount: 1) { fails.append("有待轉不該卸載") }
        if !RecordingController.canUnloadWhisperWithPending(isTranscribing: false, queuedCount: 0, state: .idle, liveTranscribeEnabled: true, pendingCount: 0) { fails.append("沒待轉可卸載") }
        return Result(name: "TRX-06/08 閒置重轉判定＋卸載閘", passed: fails.isEmpty, detail: fails.isEmpty ? "真值表 9 組" : fails.joined(separator: "; "))
    }
}
