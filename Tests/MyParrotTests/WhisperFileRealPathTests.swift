import Testing
import Foundation
@testable import MyParrotCore

/// TR-28 真路徑(鐵則 3):`MP_WHISPER_REAL_FILE=<m4a 路徑> swift test --filter WhisperFileRealPathTests` 才跑。
/// 路徑只在環境變數、不進 repo;只輸出數字(句數／不重複數／最高重複),文字內容不落檔,
/// 除非另給 `MP_WHISPER_OUT=<路徑>`(本機看品質用)。模型 = `MP_WHISPER_MODEL` 或現用模型。
/// 修前對照(10/20 19:28 場):2770 句只有 94 種、單句最多重複 1038 次。
@Suite("Whisper 檔案重轉真路徑(MP_WHISPER_REAL_FILE 才跑)")
struct WhisperFileRealPathTests {
    static var path: String? { ProcessInfo.processInfo.environment["MP_WHISPER_REAL_FILE"] }

    @Test("TR-28 真檔重轉不重複率 ≥80%、最高重複 ≤10", .enabled(if: path != nil))
    func realFile() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(Self.path))
        let modelURL = try #require(env["MP_WHISPER_MODEL"].map { URL(fileURLWithPath: $0) } ?? WhisperModelStore.activeModelURL())
        let engine = WhisperCppEngine(modelURL: modelURL)
        let provider = WhisperCppFileProvider(engine: engine)
        let t0 = Date()
        let lines = try await provider.transcribeFile(url, locale: Locale(identifier: "zh-TW"))
        let secs = Int(Date().timeIntervalSince(t0))
        func stats(_ isYou: Bool) -> (lines: Int, unique: Int, top: Int) {
            var counts: [String: Int] = [:]
            for l in lines where l.isYou == isYou { counts[l.text, default: 0] += 1 }
            return (counts.values.reduce(0, +), counts.count, counts.values.max() ?? 0)
        }
        let you = stats(true), other = stats(false)
        let total = lines.count, unique = Set(lines.map(\.text)).count
        let summary = "secs=\(secs) model=\(modelURL.lastPathComponent) lines=\(total) unique=\(unique) you=\(you) other=\(other)"
        print("TR-28 real: \(summary)")
        try? (summary + "\n").write(to: URL(fileURLWithPath: "/tmp/myparrot-tr28-stats.txt"), atomically: true, encoding: .utf8)
        if let out = env["MP_WHISPER_OUT"] {
            let text = lines.map { "\($0.isYou ? "你" : "對方") \(String(format: "%.1f", $0.start)): \($0.text)" }.joined(separator: "\n")
            try? text.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        }
        #expect(total > 0)
        #expect(Double(unique) / Double(max(total, 1)) >= 0.8, "不重複率 \(unique)/\(total)")
        #expect(max(you.top, other.top) <= 10, "最高重複 you=\(you.top) other=\(other.top)")
        await engine.unload()
    }
}
