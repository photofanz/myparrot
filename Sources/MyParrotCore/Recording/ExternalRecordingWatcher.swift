import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// #949 第一段(REC-35):監看 `~/.config/myparrot/`(租約／state.json／commands)與錄音資料夾(補 #955:
/// 別的進程發布成品後列表要自己出現)。`DispatchSource.makeFileSystemObjectSource(O_EVTONLY)` 目錄層級的
/// write/rename/delete 事件 ⇒ `onChange`;另有 2 秒保底輪詢(事件漏接、目錄被刪掉重建時也追得上)。
/// 回呼在內部序列佇列上執行,呼叫端自己 hop 回主執行緒。
public final class ExternalRecordingWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MyParrot.ExternalRecordingWatcher")
    private let onChange: @Sendable () -> Void
    private let interval: TimeInterval
    // 以下只在 queue 上讀寫
    private var directories: [URL]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?

    public init(directories: [URL], interval: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        self.directories = directories
        self.interval = interval
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
        for s in sources.values { s.cancel() }
    }

    public func start() {
        queue.async { [self] in
            attachAll()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.attachAll()       // 目錄後來才建/被刪掉重建 ⇒ 重新掛
                self.onChange()
            }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            for s in sources.values { s.cancel() }
            sources.removeAll()
        }
    }

    /// 錄音資料夾換了(設定頁改路徑)⇒ 換監看目標。
    public func setDirectories(_ dirs: [URL]) {
        queue.async { [self] in
            directories = dirs
            let keep = Set(dirs.map(\.path))
            for (path, s) in sources where !keep.contains(path) { s.cancel(); sources[path] = nil }
            attachAll()
        }
    }

    private func attachAll() {
        for dir in directories where sources[dir.path] == nil {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }   // 還不存在:保底輪詢會再試
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                queue: queue)
            let path = dir.path
            src.setEventHandler { [weak self, weak src] in
                guard let self, let src else { return }
                if !src.data.intersection([.rename, .delete]).isEmpty {
                    // 目錄本身被改名/刪掉:放掉這個 fd,下一輪保底再掛新的
                    src.cancel(); self.sources[path] = nil
                }
                self.onChange()
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources[path] = src
        }
    }
}
