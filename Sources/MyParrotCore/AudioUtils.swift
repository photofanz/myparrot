import Foundation
import AVFoundation

extension AVAudioPCMBuffer {
    /// Peak-ish RMS level (0...1) across channel 0, for the live meters.
    var rmsLevel: Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let n = Int(frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        return min(1, sqrt(sum / Float(n)) * 4) // small gain so quiet speech is visible
    }
}

/// Minimal thread-safe FIFO of Float samples (one per recorded channel).
///
/// AUD-29 / BUG-19: starvation padding used to butt raw zeros straight against
/// real signal — every pad = two hard step discontinuities = an audible click
/// (2,171 mid-speech micro zero-gaps measured in one 23-min recording). The
/// pad/resume boundaries are now linearly ramped over ~5 ms so padding, when it
/// does happen, stays inaudible.
final class SampleQueue {
    private var storage: [Float] = []
    private let lock = NSLock()
    /// Last real sample handed out — the starting point for a pad's fade-out.
    private var lastSample: Float = 0
    /// True while the previous drain ended in padding → next real samples fade in.
    private var wasPadding = false
    /// ~5 ms at 48 kHz.
    static let rampLength = 240

    func append(_ samples: [Float]) {
        lock.lock(); storage.append(contentsOf: samples); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return storage.count
    }

    /// Removes and returns up to `n` samples; pads with silence if fewer are
    /// available. Boundaries into/out of padding are ramped (see class doc).
    func drain(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let take = Swift.min(n, storage.count)
        var out = Array(storage[0..<take])
        storage.removeFirst(take)
        if take > 0 {
            if wasPadding {   // real signal resumes after a padded stretch → fade in
                let r = Swift.min(Self.rampLength, take)
                for i in 0..<r { out[i] *= Float(i) / Float(r) }
                wasPadding = false
            }
            lastSample = out[take - 1]
        }
        if take < n {         // starved → pad, fading out from the last real sample
            let padCount = n - take
            var pad = [Float](repeating: 0, count: padCount)
            if !wasPadding, lastSample != 0 {
                let r = Swift.min(Self.rampLength, padCount)
                for i in 0..<r { pad[i] = lastSample * (1 - Float(i + 1) / Float(r)) }
            }
            out.append(contentsOf: pad)
            wasPadding = true
            lastSample = 0
        }
        return out
    }

    func clear() {
        lock.lock(); storage.removeAll(); lastSample = 0; wasPadding = false; lock.unlock()
    }
}

/// Converts arbitrary input buffers to 48 kHz mono Float and returns the samples.
final class MonoDownconverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(sampleRate: Double = 48_000) {
        target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate,
                               channels: 1,
                               interleaved: false)!
    }

    func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        if sourceFormat != input.format {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { return [] }

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

/// 電平表顯示刻度(Eric 2026-08-23 拍板「三處都改真 dB 刻度」):
/// Core 的 level 值 = min(1, RMS×4)(見 `rmsLevel`),所以 value 1.0 ≡ RMS −12 dBFS,
/// value 0.16 ≡ 一般語音 −28 dBFS。顯示改成 dB 線性:**底 −50 dBFS → 0%、頂 −12 dBFS
/// (= 現有 ×4 上限)→ 100%**;語音 −28 ≈ 58%(12/20)、小聲 −40 ≈ 26%。底原設 −60,
/// Eric 22:28 實機截圖 Yeti 沒講話亮 3/20(≈ −53 dBFS 底噪)→ 底抬到 −50,底噪落進
/// 「有訊號至少 1 段」那一格(segments 的 0.005 ≈ −58 dBFS 門檻保留,「收音中」仍看得到一格)。線性刻度下語音只佔 15%,看起來像沒收到音。
public enum MeterScale {
    public static let floorDB: Float = -50
    public static let ceilDB: Float = -12
    /// value(0…1,Core 標度)→ 顯示比例 0…1。
    public static func fraction(_ value: Float) -> Float {
        guard value > 0 else { return 0 }
        let rms = min(1, value) / 4
        let db = 20 * log10f(rms)
        return min(1, max(0, (db - floorDB) / (ceilDB - floorDB)))
    }
    /// 段數映射:有訊號(value > 0.005)至少亮 1 段(延續 UI-22「收音中永遠看得到」語意)。
    public static func segments(_ value: Float, of count: Int) -> Int {
        guard value > 0.005 else { return 0 }
        return max(1, Int((fraction(value) * Float(count)).rounded()))
    }
}
