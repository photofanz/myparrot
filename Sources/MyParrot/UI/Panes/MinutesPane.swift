import SwiftUI
import MyParrotCore

/// #2438 M5:會議記錄直欄＝`MinutesPaneView`(shell:更新時間／tokens、四段＋時間軸、複製／貼到筆記／在編輯器打開、
/// 結束後一鍵產生)。只在 `ModelBackendRegistry.isEnabled(.minutes)` 時出現(B2);Phase 1 資料由 DEBUG 假供應商餵。
struct MinutesPane: View {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState
    @State private var loc = Localizer.shared

    var body: some View {
        if let n = uiState.notes {
            MinutesPaneView(minutes: n.minutes, recordingState: controller.state,
                            hasTarget: !n.isDraft, canGenerate: n.canGenerateMinutes(controller: controller),
                            onUpdateNow: { Task { await n.updateMinutesNow(controller: controller) } },
                            onPasteToNotes: { md in
                                n.appendBlock(md)
                                if !uiState.panes.open.contains(.notes) { uiState.panes.toggle(.notes) }
                            })
        } else {
            PaneEmptyState(kind: .minutes, message: L("會議記錄草稿會顯示在這裡"))
        }
    }
}
