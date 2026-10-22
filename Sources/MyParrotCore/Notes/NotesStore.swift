import Foundation
import Observation

/// 排程器抽象:讓 debounce 可注入(SelfTest 用手動時鐘,不必真的等 1 秒)。
@MainActor
public protocol NotesSaveScheduling: AnyObject {
    /// `delay` 秒後在主執行緒跑 `action`;回傳的 token 可取消。
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any NotesScheduledTask
    /// 現在時間(與 `schedule` 同一個時鐘)。
    var now: Date { get }
}

@MainActor
public protocol NotesScheduledTask: AnyObject {
    func cancel()
}

/// 正式版排程器:`Task.sleep` 後在 MainActor 執行。
@MainActor
public final class LiveNotesSaveScheduler: NotesSaveScheduling {
    public init() {}
    public var now: Date { Date() }
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any NotesScheduledTask {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return LiveToken(task)
    }

    private final class LiveToken: NotesScheduledTask {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }
}

/// 一份筆記的編輯狀態＋自動存檔(#2438 NOTE-01／NOTE-02)。
///
/// - `setText` 啟動 debounce(預設 1 秒);連續打字時另有 `maxWait`(預設 3 秒)上限,
///   避免一直打字就一直不存(`kill -9` 最多丟 `maxWait` 秒內的字)。
/// - `flush()` 原子寫:先寫 `<url>.tmp-<uuid>` 再 `replaceItemAt`(檔還不存在就 `moveItem`);內容沒變不寫。
/// - 錯誤進 `lastError`,不拋。讀檔失敗(非「不存在」)⇒ 不接管那個檔,避免之後把讀不懂的檔覆蓋成空白。
@MainActor
@Observable
public final class NotesStore {
    public private(set) var text: String = ""
    public private(set) var url: URL?
    public private(set) var isDirty = false
    public private(set) var lastSavedAt: Date?
    public private(set) var lastError: String?
    /// 實際寫檔次數(診斷/測試用)。
    public private(set) var writeCount = 0

    public let debounce: TimeInterval
    public let maxWait: TimeInterval
    private let scheduler: any NotesSaveScheduling
    private let fm: FileManager
    /// 磁碟上(或視同磁碟上)的內容;`text` 與它不同才寫。
    @ObservationIgnored private var savedText: String = ""
    @ObservationIgnored private var pending: (any NotesScheduledTask)?
    @ObservationIgnored private var firstUnsavedAt: Date?

    public init(debounce: TimeInterval = 1.0, maxWait: TimeInterval = 3.0,
                scheduler: (any NotesSaveScheduling)? = nil, fm: FileManager = .default) {
        self.debounce = debounce
        self.maxWait = max(debounce, maxWait)
        self.scheduler = scheduler ?? LiveNotesSaveScheduler()
        self.fm = fm
    }

    // MARK: 載入

    /// 換到另一份筆記。先 `flush()` 目前這份;flush 失敗 ⇒ 不換(回 false,`lastError` 有原因),免得丟字。
    /// - 檔不存在 ⇒ `text = placeholder`(預設空字串),**不是錯**,也不立刻建檔(使用者真的打字才寫)。
    /// - 讀檔失敗(權限、非 UTF-8…)⇒ `url = nil`、`text = ""`、回 false;不會把那個檔覆蓋掉。
    @discardableResult
    public func load(url newURL: URL, placeholder: String = "") -> Bool {
        guard flush() else { return false }
        cancelPending()
        if !fm.fileExists(atPath: newURL.path) {
            adopt(url: newURL, text: placeholder, onDisk: placeholder)
            lastError = nil
            return true
        }
        do {
            let s = try String(contentsOf: newURL, encoding: .utf8)
            adopt(url: newURL, text: s, onDisk: s)
            lastError = nil
            return true
        } catch {
            adopt(url: nil, text: "", onDisk: "")
            lastError = "read \(newURL.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    // MARK: 編輯

    /// 使用者改字。內容一樣 ⇒ 什麼都不做;否則標 dirty 並(重)排 debounce。
    public func setText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = text != savedText
        guard isDirty, url != nil else { cancelPending(); firstUnsavedAt = nil; return }
        let now = scheduler.now
        if firstUnsavedAt == nil { firstUnsavedAt = now }
        let waited = now.timeIntervalSince(firstUnsavedAt ?? now)
        let delay = max(0, min(debounce, maxWait - waited))
        cancelPending()
        pending = scheduler.schedule(after: delay) { [weak self] in
            self?.pending = nil
            self?.flush()
        }
    }

    // MARK: 存檔

    /// 立刻寫(取消排程中的 debounce)。沒有 url 或內容沒變 ⇒ 不寫、回 true。寫失敗 ⇒ `lastError`、回 false,保持 dirty。
    @discardableResult
    public func flush() -> Bool {
        cancelPending()
        guard let url else { return true }
        guard text != savedText else {
            isDirty = false
            firstUnsavedAt = nil
            return true
        }
        let snapshot = text
        do {
            try Self.atomicWrite(snapshot, to: url, fm: fm)
            savedText = snapshot
            isDirty = false
            firstUnsavedAt = nil
            lastSavedAt = scheduler.now
            lastError = nil
            writeCount += 1
            return true
        } catch {
            lastError = "save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// 草稿接到剛開錄的那場(NOTE-01):先 flush 目前這份,再
    /// - 草稿存在、`<stem>.notes.md` 不存在 ⇒ 草稿改名成它;
    /// - 草稿存在、目標也存在(理論上 `uniqueFileName` 已避開)⇒ **不覆蓋**:草稿內容接在目標後面(空一行),寫成功才刪草稿;
    /// - 草稿不存在 ⇒ 目標存在就照讀;不存在就以 `initialText(title:)` 當內容,**不立刻建檔**(使用者打字才寫)。
    /// - title 省略 ⇒ 用 stem 的標題部分(去掉日期時間前綴)。
    /// 完成後這個 store 指向 `<stem>.notes.md`。回 false ＝ 失敗(`lastError` 有原因,草稿保留不動)。
    @discardableResult
    public func attachDraft(to stem: URL, title: String? = nil) -> Bool {
        guard flush() else { return false }
        cancelPending()
        let doc = NotesDocument(stem: stem)
        let target = doc.url
        let draft = NotesDocument.draftURL(in: stem.deletingLastPathComponent())
        let heading = NotesDocument.initialText(title: title ?? SidecarSet.splitName(stem.lastPathComponent).title)
        do {
            if fm.fileExists(atPath: draft.path) {
                if !fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: draft, to: target)
                } else {
                    let existing = try String(contentsOf: target, encoding: .utf8)
                    let draftText = try String(contentsOf: draft, encoding: .utf8)
                    let joined = Self.appending(draftText, to: existing)
                    try Self.atomicWrite(joined, to: target, fm: fm)
                    writeCount += 1
                    try? fm.removeItem(at: draft)   // 內容已併進目標;這是我們自己的草稿檔,不是錄音
                }
                let s = try String(contentsOf: target, encoding: .utf8)
                adopt(url: target, text: s, onDisk: s)
            } else if fm.fileExists(atPath: target.path) {
                let s = try String(contentsOf: target, encoding: .utf8)
                adopt(url: target, text: s, onDisk: s)
            } else {
                adopt(url: target, text: heading, onDisk: heading)
            }
            lastError = nil
            return true
        } catch {
            lastError = "attach draft → \(target.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// 錄音改名後,檔已被 `SidecarSet.performRename` 搬走:只換指向,不重讀、不丟未存的字。
    /// App 層順序:`flush()` → `RecordingController.rename` → `retarget(to:)`。
    public func retarget(to newURL: URL) {
        url = newURL
    }

    /// 放掉目前這份(取消排程、不寫檔)。錄音丟進垃圾桶後用:不然排程中的存檔會在原路徑長出一個孤兒 `.notes.md`。
    /// App 層順序:`flush()` → `RecordingController.trash` → `detach()`。
    public func detach() {
        cancelPending()
        adopt(url: nil, text: "", onDisk: "")
        lastError = nil
    }

    // MARK: 內部

    private func adopt(url: URL?, text: String, onDisk: String) {
        self.url = url
        self.text = text
        self.savedText = onDisk
        self.isDirty = text != onDisk
        self.firstUnsavedAt = nil
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// 寫 `<url>.tmp-<uuid>` → `replaceItemAt`(目標不存在則 `moveItem`)。失敗時清掉自己的 tmp。
    nonisolated static func atomicWrite(_ text: String, to url: URL, fm: FileManager) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp-" + UUID().uuidString)
        do {
            try Data(text.utf8).write(to: tmp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// 草稿接在既有內容後面:中間保證空一行。
    nonisolated static func appending(_ addition: String, to base: String) -> String {
        guard !addition.isEmpty else { return base }
        guard !base.isEmpty else { return addition }
        var b = base
        while b.hasSuffix("\n") { b.removeLast() }
        return b + "\n\n" + addition
    }
}
