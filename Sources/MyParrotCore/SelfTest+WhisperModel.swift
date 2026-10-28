import Foundation

/// BUG-39／CLT-01(公開倉 issue #1,2026-10-28):Whisper 模型大小檢查的單位。`approxMB` 與 `isValid` 必須同一個單位(十進位 MB),
/// 三個常數釘在 HuggingFace `ggerganov/whisper.cpp` 的 blob 位元數;正控＝舊常數 2,264,000,000 B 的 q5_0 必須被拒。
extension SelfTest {

    /// HF API(`?blobs=true`,2026-10-28 查)的 blob 位元數;改模型檔要連這張表一起改。
    static let whisperUpstreamBytes: [String: Int] = [
        "ggml-large-v3-turbo.bin": 1_624_555_275,
        "ggml-large-v3-q5_0.bin": 1_081_140_203,
        "ggml-large-v3.bin": 3_095_033_483
    ]

    static func whisperModelSize() -> Result {
        var fails: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp_whisper_size_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return Result(name: "CLT-01 Whisper 模型大小檢查單位", passed: false, detail: "暫存目錄建不出來:\(error)")
        }
        defer {
            if (try? FileManager.default.removeItem(at: dir)) == nil { print("⚠️ CLT-01 暫存目錄沒清掉:\(dir.path)") }
        }

        /// 稀疏檔:只設邏輯長度,不真的寫 3 GB。
        func sparse(_ name: String, bytes: Int) -> URL? {
            let u = dir.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: u.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: u) else { return nil }
            defer { try? h.close() }
            do { try h.truncate(atOffset: UInt64(bytes)) } catch { return nil }
            return u
        }

        for m in WhisperModel.knownModels {
            guard let bytes = whisperUpstreamBytes[m.fileName] else { fails.append("\(m.id) 不在上游位元數表"); continue }
            // 1. 常數必須是十進位 MB、跟上游差 < 1 MB
            if abs(m.approxMB - Int((Double(bytes) / 1_000_000).rounded())) > 1 { fails.append("\(m.id) approxMB=\(m.approxMB) 不等於上游 \(bytes) B") }
            // 2. 上游位元數的檔必須通過
            guard let u = sparse(m.fileName, bytes: bytes) else { fails.append("建不出 \(m.fileName) 稀疏檔"); continue }
            if !WhisperModelStore.isValid(u, approxMB: m.approxMB) { fails.append("\(m.id) 上游大小 \(bytes) B 被拒") }
            // 3. 顯示字串的 GB 要跟常數一致(BUG-39 的 2.3GB)
            let gb = String(format: "%.1fGB", Double(m.approxMB) / 1000)
            if !m.display.contains(gb) { fails.append("\(m.id) 顯示「\(m.display)」缺 \(gb)") }
            // 4. ±10% 邊界(整數除法:approxMB*9/10 與 *11/10)
            let lo = m.approxMB * 9 / 10, hi = m.approxMB * 11 / 10
            for (factor, want) in [(0.89, false), (0.91, true), (1.09, true), (1.11, false)] {
                let b = Int(Double(m.approxMB) * factor * 1_000_000)
                guard let v = sparse("edge-\(m.id)-\(factor)", bytes: b) else { fails.append("\(m.id) ×\(factor) 邊界檔建不出,未執行"); continue }
                if WhisperModelStore.isValid(v, approxMB: m.approxMB) != want { fails.append("\(m.id) ×\(factor)(\(b / 1_000_000) MB,窗 \(lo)～\(hi))應\(want ? "收" : "拒")") }
            }
        }
        // 正控:舊常數 2264 MB 的 q5_0 檔必須被拒(若又把單位弄混,這條先紅);前置失敗也算失敗,不准靜默跳過
        if let q = WhisperModel.knownModels.first(where: { $0.id == "large-v3-q5_0" }) {
            if let bogus = sparse("bogus-q5", bytes: 2_264_000_000) {
                if WhisperModelStore.isValid(bogus, approxMB: q.approxMB) { fails.append("正控:2,264,000,000 B 的 q5_0 不該通過") }
            } else { fails.append("正控檔建不出來,正控未執行") }
        } else { fails.append("找不到 large-v3-q5_0,正控未執行") }
        // 邊界精確到位元(二審):1081 MB ⇒ 窗 (972.9, 1189.1) MB,972,900,001 B 收、972,900,000 B 拒
        if let q = WhisperModel.knownModels.first(where: { $0.id == "large-v3-q5_0" }) {
            let lo = Int64(q.approxMB) * 1_000_000 * 9 / 10
            for (b, want) in [(Int(lo) + 1, true), (Int(lo), false)] {
                if let u = sparse("exact-\(b)", bytes: b) {
                    if WhisperModelStore.isValid(u, approxMB: q.approxMB) != want { fails.append("精確邊界 \(b) B 應\(want ? "收" : "拒")") }
                } else { fails.append("精確邊界檔建不出來") }
            }
        }
        if (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ggml-large-v3.bin").path)[.size] as? Int) != 3_095_033_483 {
            fails.append("稀疏檔 size 屬性不是邏輯長度,測試本身無效")
        }
        return Result(name: "CLT-01 Whisper 模型大小檢查單位", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "3 個上游位元數通過/顯示 GB 一致/±10% 四個邊界/正控 2264MB 拒" : fails.joined(separator: ";"))
    }
}
