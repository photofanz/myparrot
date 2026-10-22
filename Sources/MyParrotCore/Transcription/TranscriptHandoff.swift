import Foundation

/// #2483 C(Eric 2026-10-20 15:31 A1):會後 Whisper 重轉的「先落地、再升級、再接回」。
/// 純函式與 sidecar 讀寫:已接受的校正持久化到 `<stem>.corrections.json`,重轉完用字串比對重套到新稿;
/// 即時稿在重轉前另存 `<stem>.live.srt` 給人對照。
public struct AcceptedCorrection: Codable, Sendable, Equatable {
    public var original: String
    public var suggestion: String
    public var reason: String
    /// 當初那一段的錄音經過秒數(重套時先找 ±window 秒內的行)。
    public var at: TimeInterval

    public init(original: String, suggestion: String, reason: String, at: TimeInterval) {
        self.original = original; self.suggestion = suggestion; self.reason = reason; self.at = at
    }
}

public enum TranscriptHandoff {
    public static let correctionsExt = "corrections.json"
    public static let liveExt = "live.srt"

    public static func correctionsURL(stem: URL) -> URL { SidecarSet.url(stem: stem, ext: correctionsExt) }
    public static func liveURL(stem: URL) -> URL { SidecarSet.url(stem: stem, ext: liveExt) }

    public static func load(stem: URL) -> [AcceptedCorrection] {
        guard let data = try? Data(contentsOf: correctionsURL(stem: stem)),
              let list = try? JSONDecoder().decode([AcceptedCorrection].self, from: data) else { return [] }
        return list
    }

    public static func save(_ list: [AcceptedCorrection], stem: URL) {
        let url = correctionsURL(stem: stem)
        if list.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func append(_ c: AcceptedCorrection, stem: URL) {
        var list = load(stem: stem)
        list.removeAll { $0.original == c.original && $0.suggestion == c.suggestion && abs($0.at - c.at) < 0.5 }
        list.append(c)
        save(list, stem: stem)
    }

    public static func remove(original: String, suggestion: String, stem: URL) {
        var list = load(stem: stem)
        list.removeAll { $0.original == original && $0.suggestion == suggestion }
        save(list, stem: stem)
    }

    /// 重套:每則先在 ±window 秒內找含 `original` 的行,找不到再全文找第一個;都沒有算 unmatched。
    /// 一行只換第一次出現;同一則不重複套。
    public static func reapply(_ accepted: [AcceptedCorrection], to lines: [TranscriptLine],
                               window: TimeInterval = 10) -> (lines: [TranscriptLine], unmatched: Int) {
        var out = lines
        var unmatched = 0
        for c in accepted {
            let near = out.indices.filter { abs(out[$0].start - c.at) <= window && out[$0].text.contains(c.original) }
            let idx = near.first ?? out.indices.first { out[$0].text.contains(c.original) }
            guard let i = idx, let r = out[i].text.range(of: c.original) else { unmatched += 1; continue }
            out[i].text.replaceSubrange(r, with: c.suggestion)
        }
        return (out, unmatched)
    }
}
