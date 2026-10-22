import SwiftUI
import AppKit
import MyParrotCore

/// #2438 會議記錄面板內容（shell）：標題列「更新於 HH:MM · 每 N 分 · N.Nk tokens」＋「立即更新 ⌘⇧U」、
/// 內容＝`MinutesMarkdown.render` 的四段＋時間軸（唯讀，走 `MarkdownPreview`）、底部三鈕（複製 Markdown ⌘⇧C、
/// 貼到筆記、在編輯器打開）、待錄音空狀態、結束後頂端「產生會議記錄」大鈕。
struct MinutesPaneView: View {
    let minutes: MinutesController
    let recordingState: RecordingState
    /// 有附著的場(非草稿):結束後或選中某場。
    var hasTarget: Bool = true
    /// MIN-09:找得到逐字稿來源(進行中的場、或該場有 `.srt`);false ⇒ 鈕停用＋「先轉逐字稿」提示。
    var canGenerate: Bool = true
    var onUpdateNow: () -> Void
    var onPasteToNotes: ((String) -> Void)? = nil
    @State private var loc = Localizer.shared

    private var labels: MinutesLabels { NotesSession.localizedLabels() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if recordingState == .finished || (recordingState == .idle && hasTarget) {
                Button { onUpdateNow() } label: {
                    HStack(spacing: 6) {
                        if minutes.isUpdating { ProgressView().controlSize(.small) }
                        Label(L("產生會議記錄"), systemImage: "list.clipboard")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MPProminentButtonStyle(tint: MP.blue))
                .disabled(minutes.isUpdating || !minutes.isAvailable || !canGenerate)
                .help("\(L("產生會議記錄")) ⌘⇧U")
            }
            if hasTarget, minutes.isAvailable, !canGenerate {
                Label(L("這場還沒有逐字稿,先轉逐字稿再產生會議記錄"), systemImage: "text.badge.xmark")
                    .font(MPFont.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let md = minutes.markdown(labels: labels) {
                MarkdownPreview(text: md)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                footer(md)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.clipboard").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(emptyText).font(MPFont.label).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).lineSpacing(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(MP.spM)
            }
            if let e = minutes.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(MPFont.caption).foregroundStyle(.red).lineLimit(2)
            }
            if minutes.autoPaused {
                Label(Lf("自動更新已連續失敗 %@ 次,已暫停;按「立即更新」重試", ["\(MinutesRolling.autoPauseThreshold)"]),
                      systemImage: "pause.circle").font(MPFont.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var emptyText: String {
        if let r = minutes.unavailableReason { return r }
        if !minutes.isAvailable { return L("尚未設定會議記錄的模型後端") }
        if recordingState == .idle {
            return String(format: L("開始錄音後每 %@ 分鐘自動整理一次（可在設定調整或關閉；也可隨時按「立即更新」）"),
                          "\(minutes.cadenceMinutes)")
        }
        return L("會議記錄尚未產生")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(meta).font(MPFont.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            Spacer(minLength: 4)
            Button { onUpdateNow() } label: {
                HStack(spacing: 4) {
                    if minutes.isUpdating { ProgressView().controlSize(.small) }
                    Text(L("立即更新"))
                    ShortcutBadge(symbol: "⌘⇧U", size: 9)
                }
            }
            .controlSize(.small)
            .disabled(minutes.isUpdating || !minutes.isAvailable || !hasTarget || !canGenerate)
            .help("\(L("立即更新")) ⌘⇧U")
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let t = minutes.lastUpdate { parts.append("\(L("更新於")) \(NotesEditorPane.hhmm(t))") }
        parts.append(minutes.autoEnabled ? String(format: L("每 %@ 分"), "\(minutes.cadenceMinutes)") : L("手動"))
        let total = minutes.inputTokens + minutes.outputTokens
        // AFM-03:Apple 本機模型不回 usage,數字是估算 ⇒ 前面加「≈」。
        let approx = minutes.backendID == ModelBackendRegistry.appleFM.id ? "≈" : ""
        if total > 0 { parts.append(approx + String(format: "%.1fk tokens", Double(total) / 1000)) }
        return parts.joined(separator: " · ")
    }

    private func footer(_ md: String) -> some View {
        HStack(spacing: MP.spS) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(md, forType: .string)
            } label: {
                HStack(spacing: 3) { Text(L("複製 Markdown")); ShortcutBadge(symbol: "⌘⇧C", size: 9) }
            }
            .controlSize(.small)
            Button(L("貼到筆記")) { onPasteToNotes?(md) }.controlSize(.small).disabled(onPasteToNotes == nil)
            Spacer(minLength: 0)
            Button(L("在編輯器打開")) {
                if let u = minutes.markdownURL { NSWorkspace.shared.open(u) }
            }
            .controlSize(.small)
            .disabled(minutes.markdownURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
        }
    }
}
