import SwiftUI
import AppKit
import MyParrotCore

/// #2438 UI-53／54：檔案面板的「重新命名…」「移到垃圾桶…」對話框。
/// 真正動檔案的是 `RecordingController.rename／trash`（鎖、回滾都在 Core）；這裡只負責問、顯示錯誤、把筆記指到新路徑。
/// 呼叫順序照 report-M2 待問 7：改名＝flush → rename → retarget；丟＝flush → trash → detach。
@MainActor
enum FileActions {

    /// 這筆現在能不能改名／丟（錄音中、轉檔中、轉稿中、排隊中、檢查逐字稿中 ⇒ 不能）。
    static func isLocked(_ rec: Recording, controller: RecordingController) -> Bool {
        controller.isFileActionLocked(rec)
    }

    static func rename(_ rec: Recording, controller: RecordingController, session: NotesSession?) {
        let name = rec.url.deletingPathExtension().lastPathComponent
        let split = SidecarSet.splitName(name)
        let alert = NSAlert()
        alert.messageText = L("重新命名")
        alert.informativeText = L("同一場的錄音、逐字稿、筆記、會議記錄會一起改名；日期時間前綴不變。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = split.title
        field.placeholderString = L("會議名稱")
        alert.accessoryView = field
        alert.addButton(withTitle: L("重新命名"))
        alert.addButton(withTitle: L("取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 裁示 5：使用者自己打了同一個日期前綴 ⇒ 剝掉，避免前綴重複。
        if let p = split.prefix, title.hasPrefix(p) {
            title = String(title.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        session?.flushAll()
        do {
            let newURL = try controller.rename(rec, to: title)
            if newURL != rec.url { session?.renamed(from: rec.url, to: newURL) }
        } catch {
            showError(title: L("無法重新命名"), error)
        }
    }

    static func trash(_ rec: Recording, controller: RecordingController, session: NotesSession?) {
        let urls = SidecarSet.trashPlan(stem: SidecarSet.stem(of: rec.url))
        let alert = NSAlert()
        alert.messageText = L("移到垃圾桶")
        alert.informativeText = L("這些檔案會移到垃圾桶（可從垃圾桶救回）：") + "\n" + urls.map(\.lastPathComponent).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("移到垃圾桶"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session?.flushAll()
        do {
            try controller.trash(rec)
            session?.trashed(rec.url)
        } catch {
            showError(title: L("無法移到垃圾桶"), error)
        }
    }

    private static func showError(title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("完成"))
        alert.runModal()
    }

    static func message(for error: Error) -> String {
        guard let e = error as? SidecarError else { return "\(error)" }
        switch e {
        case .invalidTitle: return L("名稱清理後是空的，請換一個名稱。")
        case .unchanged: return L("名稱沒有變。")
        case .conflict(let names): return L("已有同名檔案：") + names.joined(separator: "、")
        case .notFound: return L("找不到這場的檔案，可能已被移走。")
        case .locked: return L("這場正在錄音、轉檔或轉逐字稿，等它完成再試。")
        case .ioFailed(let why): return why
        }
    }
}

/// 檔案列副標的 sidecar 標記：有哪個檔就亮哪個（逐字稿／筆記／記錄）。
struct SidecarChips: View {
    let stem: URL
    @State private var loc = Localizer.shared

    var body: some View {
        let has = Set(SidecarSet.existing(stem: stem).map { $0.lastPathComponent.replacingOccurrences(of: stem.lastPathComponent + ".", with: "") })
        HStack(spacing: 4) {
            chip(L("逐字稿"), on: has.contains("txt") || has.contains("srt"), color: MP.blue)
            chip(L("筆記"), on: has.contains("notes.md"), color: MP.coral)
            chip(L("記錄"), on: has.contains("minutes.md"), color: .green)
        }
    }

    @ViewBuilder private func chip(_ label: String, on: Bool, color: Color) -> some View {
        if on {
            Text(label).font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.14)))
                .foregroundStyle(color)
        }
    }
}
