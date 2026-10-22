import Foundation
import AVFoundation
import os

/// whisper.cpp 檔案轉錄:分軌(左=對方/右=你)→ 16k mono → **VAD 分塊、每塊獨立解碼** →
/// 帶時間戳合併。把「轉逐字稿」按鈕與 Phase C 自動重轉升級到 large-v3 級品質。
///
/// TR-28(#2485,Eric 2026-10-22 A1):原本整軌一次丟 `whisper_full`。whisper.cpp 的
/// `no_context` 只在呼叫開頭清一次歷史,同一次呼叫內每個 30 秒窗仍把上一窗解出的 token
/// 當 prompt(src/whisper.cpp L7101／L7290／L7791);分軌後每軌 40～100% 時間是對方在講
/// (靜音或底噪),靜音窗幻覺出一句就被餵進下一窗、鎖死到檔尾(真資料夾 48 份會後重轉稿
/// 有 36 份 dup%≥40,10/20 14:30 場你軌 479 句只有 2 種)。改成跟 live 同一套 VAD 切塊
/// (塊 ≤25 s、尾靜音 0.8 s 切、全靜音丟),每塊各自呼叫 ⇒ 真的獨立、TR-26 提示詞每塊都帶
/// (#2422 一併修)、靜音不再是幻覺素材;再過 `HallucinationGate` 連三同句壓下。
final class WhisperCppFileProvider: TranscriptionProvider, @unchecked Sendable {

    let displayName = "Whisper(本地)"
    private let engine: WhisperCppEngine
    /// 餵切塊器的粒度(0.1 s):切點誤差上限,跟 live 的 buffer 粒度同量級。
    static let feedStep = 1_600

    init(engine: WhisperCppEngine) {
        self.engine = engine
    }

    func transcribeFile(_ url: URL, locale: Locale) async throws -> [TranscriptLine] {
        let (leftURL, rightURL) = try AudioChannelSplit.splitStereoToMono(url)
        defer {
            if leftURL != url { try? FileManager.default.removeItem(at: leftURL) }
            if rightURL != url { try? FileManager.default.removeItem(at: rightURL) }
        }
        let lang = WhisperLang.code(for: locale)
        let prompt = WhisperLang.prompt(for: lang)
        let base = Date()

        let other = try await transcribeMono(leftURL, isYou: false, lang: lang, prompt: prompt, base: base)
        let you = try await transcribeMono(rightURL, isYou: true, lang: lang, prompt: prompt, base: base)
        return (other + you).sorted { $0.time < $1.time }
    }

    private func transcribeMono(_ url: URL, isYou: Bool, lang: String?,
                                prompt: String?, base: Date) async throws -> [TranscriptLine] {
        let chunks = try Self.chunk(try Self.loadMono16k(url))
        guard !chunks.isEmpty else { return [] }
        var gate = HallucinationGate()
        var out: [TranscriptLine] = []
        var suppressed = 0
        for c in chunks {
            let segs = try await engine.transcribe(samples16k: c.samples, languageCode: lang, prompt: prompt)
            for s in segs {
                var text = s.text
                if lang == "zh" { text = ZhTW.convert(text) }
                guard gate.check(text) else { suppressed += 1; continue }
                let start = Self.absoluteStart(chunkOffset: c.startOffset, segStart: s.start)
                out.append(TranscriptLine(isYou: isYou, time: base.addingTimeInterval(start),
                                          text: text, isFinal: true, start: start, duration: s.duration))
            }
        }
        if suppressed > 0 {
            os_log("MyParrot whisper file: %{public}@ 軌 %d 塊,壓下 %d 句疑似複讀", isYou ? "你" : "對方", chunks.count, suppressed)
        }
        return out
    }

    /// 整軌樣本 → VAD 塊(file profile)。<1 s 的音訊直接略過。純函式,SelfTest 覆蓋。
    static func chunk(_ samples: [Float]) throws -> [VadChunker.Chunk] {
        guard samples.count > 16_000 else { return [] }
        var chunker = VadChunker(profile: .file)
        var chunks: [VadChunker.Chunk] = []
        var i = 0
        while i < samples.count {
            let end = min(i + feedStep, samples.count)
            chunks += chunker.feed(Array(samples[i..<end]))
            i = end
        }
        if let tail = chunker.flush() { chunks.append(tail) }
        return chunks
    }

    /// 塊內段落起點 → 整檔絕對秒數。
    static func absoluteStart(chunkOffset: Int, segStart: TimeInterval) -> TimeInterval {
        Double(chunkOffset) / Double(VadChunker.rate) + segStart
    }

    /// 讀任意音檔 → 16kHz mono Float(分塊讀,不整檔進記憶體兩份)。
    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let conv = MonoDownconverter(sampleRate: 16_000)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * 16_000) + 16)
        let chunkFrames: AVAudioFrameCount = 65_536
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: chunkFrames) else { break }
            try file.read(into: buf, frameCount: chunkFrames)
            if buf.frameLength == 0 { break }
            out.append(contentsOf: conv.convert(buf))
        }
        return out
    }
}
