import SwiftUI
import MyParrotCore

// #2438 M6:設定頁「逐字稿校正」區段(CorrectionSettingsSection)併進單一「模型」區段,
// 見 `UI/Settings/ModelSettingsSection.swift`(隱私確認框、CLI 狀態、模型檔位欄都搬過去)。

/// 建議列表(CORR-08):逐則接受/忽略/還原;「全部忽略」一鍵收掉。接受前檔案不動。
struct CorrectionSuggestionList: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            HStack {
                Text(Lf("建議 %@ 則", ["\(controller.correctionSuggestions.count)"]))
                    .font(MPFont.label).foregroundStyle(.secondary)
                Spacer()
                Button(L("全部忽略")) { controller.ignoreAllCorrections() }.controlSize(.small)
                Button { controller.clearCorrections() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            ForEach(controller.correctionSuggestions) { item in
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
                .padding(.vertical, 2)
            }
        }
        .mpBanner(color: MP.blue)
    }
}
