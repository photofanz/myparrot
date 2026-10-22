import Foundation

/// Renders transcript lines as a SubRip (.srt) subtitle file — numbered cues with
/// `HH:MM:SS,mmm --> HH:MM:SS,mmm` timecodes and a speaker prefix, so the timed
/// transcript opens in any player / editor (Premiere, DaVinci, VLC, YouTube…).
public enum SRT {
    static func make(from lines: [TranscriptLine]) -> String {
        let cues = lines.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
        var out = ""
        for (i, line) in cues.enumerated() {
            let start = max(0, line.start)
            // End = start+duration; if the engine gave no duration, run up to the
            // next cue's start (min 0.5s) so the cue stays on screen, never zero-length.
            var end = line.duration > 0 ? start + line.duration : 0
            if end <= start {
                let next = i + 1 < cues.count ? cues[i + 1].start : start + 2
                end = max(next, start + 0.5)
            }
            let speaker = line.isYou ? "你" : "對方"
            out += "\(i + 1)\n\(timecode(start)) --> \(timecode(end))\n\(speaker): \(line.text)\n\n"
        }
        return out
    }

    /// `make` 的反向(#2417):把既有 `.srt` 讀回 `[TranscriptLine]`,讓校正層能對
    /// 「這次開 App 之前就轉好」的逐字稿動作。只認自己寫出的格式(編號/時間碼/
    /// 「對方: 」或「你: 」前綴);沒有前綴的 cue 視為對方。
    public static func parse(_ srt: String) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        let blocks = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard rows.count >= 3, let arrow = rows[1].range(of: " --> ") else { continue }
            let start = seconds(String(rows[1][rows[1].startIndex..<arrow.lowerBound]))
            let end = seconds(String(rows[1][arrow.upperBound...]))
            var text = rows[2...].joined(separator: "\n")
            var isYou = false
            if text.hasPrefix("你: ") { isYou = true; text = String(text.dropFirst(3)) }
            else if text.hasPrefix("對方: ") { text = String(text.dropFirst(4)) }
            guard !text.isEmpty else { continue }
            lines.append(TranscriptLine(isYou: isYou, time: Date(timeIntervalSince1970: start),
                                        text: text, isFinal: true,
                                        start: start, duration: max(0, end - start)))
        }
        return lines
    }

    /// `HH:MM:SS,mmm` → 秒;格式不對回 0。
    static func seconds(_ tc: String) -> TimeInterval {
        let parts = tc.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let ms = Int((total - Double(whole)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", whole / 3600, (whole % 3600) / 60, whole % 60, ms)
    }
}
