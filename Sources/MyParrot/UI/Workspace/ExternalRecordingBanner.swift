import SwiftUI
import MyParrotCore

/// #949 第一段 REC-35(brief §5.8):CLI(別的進程)正在錄音時,控制欄最上面的橘色橫幅。
/// 第一行「myparrot CLI 正在錄音：<名稱>　<h:mm:ss>」(心跳 >10 秒 ⇒ 尾加「（無回應）」);
/// 第二行兩個小電平(state.json 的 other／you,沿遙控器收音點的樣式)＋「已暫停」;
/// 右側「暫停／繼續」「停止」⇒ `requestExternalPause/Resume/Stop`(舊版 CLI 不認指令檔 ⇒ 只有停止,走 SIGINT)。
struct ExternalRecordingBanner: View {
    @Bindable var controller: RecordingController
    @State private var loc = Localizer.shared

    var body: some View {
        if let ext = controller.externalRecording {
            HStack(alignment: .center, spacing: MP.spS) {
                Image(systemName: "terminal.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: MP.spXS) {
                    HStack(spacing: 6) {
                        // 標籤與時間不截;只有名稱太長時從中間截(真機截圖:整句一起截會把「myparrot CLI 正在錄音」截掉)。
                        Text(L("myparrot CLI 正在錄音") + "：").fixedSize()
                        Text(ext.lease.name).lineLimit(1).truncationMode(.middle)
                        Text(Self.clock(ext.elapsed())).monospacedDigit().fixedSize()
                        if ext.unresponsive { Text(L("（無回應）")).foregroundStyle(.red).fixedSize() }
                    }
                    .font(MPFont.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    HStack(spacing: MP.spM) {
                        level(L("對方"), ext.state?.levels.other ?? 0, MP.coral)
                        level(L("你"), ext.state?.levels.you ?? 0, MP.blue)
                        if ext.paused { Text(L("已暫停")).font(MPFont.caption).foregroundStyle(.orange) }
                    }
                }
                Spacer(minLength: 0)
                if ext.supportsCommands {
                    Button(ext.paused ? L("繼續") : L("暫停")) {
                        if ext.paused { controller.requestExternalResume() } else { controller.requestExternalPause() }
                    }
                    .controlSize(.small)
                }
                Button(L("停止")) { controller.requestExternalStop() }
                    .controlSize(.small)
            }
            .mpBanner(color: .orange)
            .accessibilityElement(children: .contain)
        }
    }

    /// 小電平:圓點＋短條(標度同錄音 rmsLevel 0…1)。
    private func level(_ who: String, _ v: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(v > 0.003 ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(who).font(MPFont.caption).foregroundStyle(color).fixedSize()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color).frame(width: g.size.width * CGFloat(min(1, max(0, v))))
                }
            }
            .frame(width: 44, height: 4)
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
