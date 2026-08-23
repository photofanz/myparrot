import SwiftUI

/// UI-24 修正(Eric 2026-08-23 15:06 截圖):主要動作鈕(開始錄音/結束)原用
/// `.borderedProminent` + tint——macOS 在**視窗失焦時把 prominent 鈕降成灰底**,
/// 紅色不見、白字膠囊(onAccent)跟著看不清。這顆自繪樣式不看 key window 狀態,
/// 失焦照樣紅底白字;尺寸對齊旁邊 `.bordered` 鈕(同列的「暫停」)。
struct MPProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = MP.recRed

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(configuration.isPressed ? 0.75 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension ButtonStyle where Self == MPProminentButtonStyle {
    static var mpProminent: MPProminentButtonStyle { MPProminentButtonStyle() }
}
