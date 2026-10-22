import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// #949 第一段 REC-31:錄音中寫 `<dir>/.myparrot/inprogress/<sessionId>/audio.caf`,停止時原子發布到頂層。
/// 純檔案規則(只依賴 Foundation),`RecordingController` 與 `scripts/dev/fake-writer.swift` 共用同一份
/// ——fake-writer 直接把本檔一起編進去,矩陣驗的就是正式的發布邏輯。
public enum InprogressFiles {

    /// `<dir>/.myparrot`——MyParrot 在錄音資料夾裡的私有區(inprogress、quarantine)。舊版收割端只掃頂層,看不到這裡。
    public static func privateDir(dir: URL) -> URL {
        dir.appendingPathComponent(".myparrot", isDirectory: true)
    }

    /// `<dir>/.myparrot/inprogress`
    public static func root(dir: URL) -> URL {
        privateDir(dir: dir).appendingPathComponent("inprogress", isDirectory: true)
    }

    /// 錄音中實際寫的檔:`<dir>/.myparrot/inprogress/<sessionId>/audio.caf`。
    public static func audioURL(dir: URL, sessionId: String) -> URL {
        root(dir: dir).appendingPathComponent(sessionId, isDirectory: true).appendingPathComponent("audio.caf")
    }

    /// 發布目的地 `<dir>/<stem>.caf`,帶避讓:頂層已有同 stem 的**音檔**(.caf/.m4a)就加「 2」「 3」…。
    /// 只看音檔不看 sidecar——錄音中筆記已經以同 stem 寫了 `<stem>.notes.md`,把它算進去會讓自己避讓自己。
    public static func publishURL(dir: URL, stem: String, fm: FileManager = .default) -> URL {
        func taken(_ s: String) -> Bool {
            ["caf", "m4a"].contains { fm.fileExists(atPath: dir.appendingPathComponent("\(s).\($0)").path) }
        }
        guard taken(stem) else { return dir.appendingPathComponent("\(stem).caf") }
        var n = 2
        while taken("\(stem) \(n)") { n += 1 }
        return dir.appendingPathComponent("\(stem) \(n).caf")
    }

    public enum PublishError: Error, Equatable {
        /// inprogress 檔不存在(開錄當下 recorder 就沒建起來)——沒有東西可發布。
        case missing
        /// rename 失敗(errno);檔案留在 inprogress,等收割規則復原。
        case renameFailed(Int32)
    }

    /// 把 finalize 完的 inprogress 檔原子發布到頂層 `<stem>.caf`(撞名就換下一個後綴),成功後刪掉
    /// `inprogress/<sessionId>/` 目錄。用 `renamex_np(RENAME_EXCL)`:同卷原子、而且**絕不覆蓋**既有檔
    /// (探測與 rename 之間有人搶先寫了同名檔 ⇒ EEXIST ⇒ 再探一次)。
    public static func publish(_ src: URL, dir: URL, stem: String,
                               fm: FileManager = .default) -> Swift.Result<URL, PublishError> {
        guard fm.fileExists(atPath: src.path) else {
            try? fm.removeItem(at: src.deletingLastPathComponent())
            return .failure(.missing)
        }
        var lastErr: Int32 = EEXIST
        for _ in 0..<8 {
            let dest = publishURL(dir: dir, stem: stem, fm: fm)
            if renamex_np(src.path, dest.path, UInt32(RENAME_EXCL)) == 0 {
                try? fm.removeItem(at: src.deletingLastPathComponent())
                return .success(dest)
            }
            lastErr = errno
            if lastErr != EEXIST { break }
        }
        return .failure(.renameFailed(lastErr))
    }

    /// `<dir>/.myparrot/inprogress/` 底下有 audio.caf 的那幾場(sessionId, audio URL)。
    public static func leftovers(dir: URL, fm: FileManager = .default) -> [(sessionId: String, audio: URL)] {
        guard let ids = try? fm.contentsOfDirectory(atPath: root(dir: dir).path) else { return [] }
        return ids.sorted().compactMap { id in
            let audio = audioURL(dir: dir, sessionId: id)
            return fm.fileExists(atPath: audio.path) ? (id, audio) : nil
        }
    }
}
