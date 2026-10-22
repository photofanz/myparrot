// Apple Foundation Models 真生成探針(#2438 Phase 3 前置;2026-10-20 13:2x Eric 改 Siri 語言後驗證用)。
// 編譯:DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -parse-as-library scripts/dev/fm-gen.swift -o /tmp/fm-gen && /tmp/fm-gen
// 不可用就印 availability;可用就開一個 session 用繁中指令要一句摘要,印回應與耗時(ms)。合成句子,不含任何真資料。
import Foundation
import FoundationModels

@main struct Gen {
    static func main() async {
        let m = SystemLanguageModel.default
        guard m.isAvailable else { print("not available:", m.availability); return }
        let session = LanguageModelSession(instructions: "你是會議記錄助理。只用繁體中文回答，簡短。")
        let t0 = Date()
        do {
            let r = try await session.respond(to: "把這段逐字稿用一句話摘要：『我們決定下週三前把淺色遙控器改成銀色，Eric 負責驗收。』")
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("response(\(ms) ms):", r.content)
        } catch {
            print("error:", error)
        }
    }
}
