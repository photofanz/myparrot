import AVFoundation
import Accelerate

/// UI-28b(Phase 2,2026-08-23):錄音檔的雙聲道 RMS 概覽——每聲道 N 桶、0…1
/// 正規化,給播放列的波形縮圖畫(上半=左=對方、下半=右=你)。
public struct Waveform: Sendable, Equatable {
    public let left: [Float]
    public let right: [Float]
    public let duration: TimeInterval
    public var bucketCount: Int { left.count }

    public init(left: [Float], right: [Float], duration: TimeInterval) {
        self.left = left; self.right = right; self.duration = duration
    }

    /// 合併相鄰桶成 n 桶(窄版 320pt 用 60–80 桶,設計稿 v2);每組取最大值,
    /// 讓短促的說話段不會被平均掉。n ≥ bucketCount 時原樣回傳。
    public func downsampled(to n: Int) -> Waveform {
        guard n > 0, n < bucketCount else { return self }
        func fold(_ a: [Float]) -> [Float] {
            (0..<n).map { i in
                let lo = i * a.count / n
                let hi = max(lo + 1, (i + 1) * a.count / n)
                return a[lo..<hi].max() ?? 0
            }
        }
        return Waveform(left: fold(left), right: fold(right), duration: duration)
    }
}

public enum WaveformAnalyzer {
    public enum Failure: Error { case emptyFile, unreadable }

    /// 分段讀檔(每段 `chunkFrames`,不整檔進記憶體——37 分鐘 48k 立體聲整檔是
    /// 850MB float;nilError 教訓:絕不讀過檔尾,迴圈以 framePosition < length 守門)。
    /// 單聲道檔:右聲道複製左聲道(畫面上下對稱,不假裝「你沒聲音」)。
    /// 正規化:兩聲道共用同一個基準(第 95 百分位,保留對方/你的相對大小;見下);
    /// 基準 < 0.005(幾乎全靜音)就不放大,直接回 0,免得把底噪放大成假波形。
    public static func analyze(url: URL, buckets: Int = 240,
                               chunkFrames: AVAudioFrameCount = 65_536) throws -> Waveform {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        let sr = file.processingFormat.sampleRate
        guard total > 0, sr > 0, buckets > 0 else { throw Failure.emptyFile }
        let channels = Int(file.processingFormat.channelCount)
        guard channels >= 1 else { throw Failure.unreadable }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            throw Failure.unreadable
        }
        var sumSq = [[Double]](repeating: [Double](repeating: 0, count: buckets), count: min(channels, 2))
        var counts = [Int](repeating: 0, count: buckets)
        while file.framePosition < total {
            // 配合外層 Task 取消(每段 ~1.4 秒音訊檢查一次);同步讀檔本身不可中斷。
            if Task.isCancelled { throw CancellationError() }
            let start = file.framePosition
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { throw Failure.unreadable }
            // 以「桶」為單位切 chunk,每段用 vDSP_svesq 向量化算平方和——
            // 108 分鐘檔逐 sample 迴圈在 debug build 要 >100 秒(2026-08-23 實測超時),
            // 向量化後秒級。
            var i = 0
            while i < n {
                let pos = Int64(start) + Int64(i)
                let b = min(buckets - 1, Int(pos * Int64(buckets) / total))
                let bucketEnd = (Int64(b + 1) * total + Int64(buckets) - 1) / Int64(buckets)
                let len = max(1, min(n - i, Int(bucketEnd - pos)))
                for c in 0..<sumSq.count {
                    var ss: Float = 0
                    vDSP_svesq(data[c] + i, 1, &ss, vDSP_Length(len))
                    sumSq[c][b] += Double(ss)
                }
                counts[b] += len
                i += len
            }
        }
        var rms = sumSq.map { ch in
            (0..<buckets).map { b in counts[b] > 0 ? Float((ch[b] / Double(counts[b])).squareRoot()) : 0 }
        }
        // 正規化基準用第 95 百分位而非最大值:一聲碰撞/咳嗽的尖峰會把整場對話壓成
        // 一條線(2026-08-23 108 分鐘真檔實測:前 20% 有一段大聲,其餘全看不見)。
        // 超過基準的桶夾到 1。
        let sorted = rms.flatMap { $0 }.sorted()
        let scale = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        if scale >= 0.005 {
            rms = rms.map { $0.map { min(1, $0 / scale) } }
        } else {
            rms = rms.map { $0.map { _ in 0 } }
        }
        let left = rms[0]
        let right = rms.count > 1 ? rms[1] : rms[0]
        return Waveform(left: left, right: right, duration: Double(total) / sr)
    }
}
