import SwiftUI
import MyParrotCore

// #2438 M6:設定頁「逐字稿校正」區段(CorrectionSettingsSection)併進單一「模型」區段,
// 見 `UI/Settings/ModelSettingsSection.swift`(隱私確認框、CLI 狀態、模型檔位欄都搬過去)。

/// 建議列表(CORR-08):逐則接受/忽略/還原;「全部忽略」一鍵收掉。接受前檔案不動。
///
/// UI-59(BUG-38,Eric 2026-10-24 真稿 77 則截圖):清單**自己捲**。原本 ForEach 直接疊在逐字稿欄的外層 VStack,
/// 沒有捲動容器,建議一多就把欄撐滿、被 `PaneContainer` 裁掉,逐字稿捲動區被壓到 minHeight。
/// 現在標題列(則數／全部忽略／×)固定在外,項目包進 ScrollView,高度＝min(量到的內容高度, `maxListHeight`):
/// 少於上限就貼內容(2～3 則不留空白),超過就在清單裡捲,逐字稿留在下面。
struct CorrectionSuggestionList: View {
    @Bindable var controller: RecordingController
    /// UI-60:選中的建議 id(住 `AppUIState.focusedSuggestionID`,TranscriptPane 傳進來);點列的空白處選它。
    var selectedID: String? = nil
    var onSelect: (PendingCorrection) -> Void = { _ in }
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            HStack {
                Text(Lf("建議 %@ 則", ["\(controller.correctionSuggestions.count)"]))
                    .font(MPFont.label).foregroundStyle(.secondary)
                Spacer()
                Button(L("全部忽略")) { controller.ignoreAllCorrections() }.controlSize(.small)
                Button { controller.clearCorrections() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.correctionSuggestions) { item in
                        row(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: CGFloat(CorrectionListLayout.height(content: Double(contentHeight))))   // 最高 360pt(欄高 ~850 時約四成)
        }
        .mpBanner(color: MP.blue)
    }

    /// UI-60:列的空白處可點 ⇒ 選中(藍底)並在列內展開該段完整原句;接受／忽略／還原鈕照舊各自吃自己的點擊。
    @ViewBuilder
    private func row(_ item: PendingCorrection) -> some View {
        let selected = item.id == selectedID
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: MP.spS) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Lf("第 %@ 段", ["\(item.suggestion.segment + 1)"]) + " · " + item.suggestion.reason)
                        .font(MPFont.caption).foregroundStyle(.tertiary)
                    HStack(spacing: MP.spXS) {
                        Text(item.suggestion.original).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(item.suggestion.suggestion).fontWeight(.semibold)
                    }.font(MPFont.caption)
                }
                Spacer()
                switch item.state {
                case .pending:
                    Button(L("接受")) { controller.acceptCorrection(item.id) }.controlSize(.small)
                    Button(L("忽略")) { controller.ignoreCorrection(item.id) }.controlSize(.small)
                case .accepted:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(L("還原")) { controller.revertCorrection(item.id) }.controlSize(.small)
                case .ignored:
                    Text(L("忽略")).font(MPFont.caption).foregroundStyle(.tertiary)
                }
            }
            if selected { originalSentence(item) }
        }
        .padding(.vertical, 3).padding(.horizontal, MP.spXS)
        .background(selected ? MP.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item) }
    }

    /// UI-60:該段完整原句,`original` 片段標色;段號越界(稿已重轉變短)⇒「原句已不在稿內」。
    @ViewBuilder
    private func originalSentence(_ item: PendingCorrection) -> some View {
        if let idx = CorrectionFocus.lineIndex(segment: item.suggestion.segment, count: controller.liveTranscript.count) {
            Text(Self.highlighted(controller.liveTranscript[idx].text, original: item.suggestion.original))
                .font(MPFont.caption).foregroundStyle(.primary).lineSpacing(2).padding(.vertical, 2)
                .textSelection(.enabled)
        } else {
            Text(L("原句已不在稿內")).font(MPFont.caption).foregroundStyle(.orange)
        }
    }

    static func highlighted(_ text: String, original: String) -> AttributedString {
        var a = AttributedString(text)
        if let r = CorrectionFocus.highlightRange(original: original, in: text),
           let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) {
            a[lo..<hi].backgroundColor = MP.coral.opacity(0.35)
            a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }
}
