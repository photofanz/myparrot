import Foundation
import CryptoKit

/// UI-28c(2026-08-23):波形快取落檔——`~/Library/Application Support/MyParrot/waveforms/
/// <sha256(路徑|大小|mtime)>.json`。key 含大小與 mtime,同名重錄/修檔自然失效;
/// 不放錄音工作目錄(多版本並存協定:共用目錄只放錄音/逐字稿,不放各版私有快取)。
/// 所有失敗都回 nil/靜默(快取只是加速,壞了就重算)。
public enum WaveformCache {
    static let version = 1

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyParrot/waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Envelope: Codable {
        var version: Int
        var left: [Float]
        var right: [Float]
        var duration: TimeInterval
    }

    /// 路徑 + 大小 + mtime(秒) → sha256 十六進位;檔不存在回 nil。
    public static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let seed = "\(url.path)|\(size.int64Value)|\(Int64(mtime.timeIntervalSince1970))"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(for key: String, in dir: URL) -> URL {
        dir.appendingPathComponent(key).appendingPathExtension("json")
    }

    public static func load(for url: URL, in dir: URL? = nil) -> Waveform? {
        guard let key = key(for: url) else { return nil }
        let f = fileURL(for: key, in: dir ?? directory)
        guard let data = try? Data(contentsOf: f),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.version == version,
              env.left.count == env.right.count, !env.left.isEmpty, env.duration > 0 else { return nil }
        return Waveform(left: env.left, right: env.right, duration: env.duration)
    }

    /// 寫到 tmp 再 rename(原子,半寫檔不會被下次 load 讀到)。
    @discardableResult
    public static func save(_ w: Waveform, for url: URL, in dir: URL? = nil) -> Bool {
        guard let key = key(for: url) else { return false }
        let target = fileURL(for: key, in: dir ?? directory)
        let tmp = target.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            let data = try JSONEncoder().encode(Envelope(version: version, left: w.left, right: w.right, duration: w.duration))
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
