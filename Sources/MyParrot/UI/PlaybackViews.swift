import SwiftUI
import MyParrotCore

// UI-27/28 (2026-08-23, Eric 拍板 3a + B):播放列展開後的兩個子元件——
// 進度列(點擊/拖曳 seek)與列內短型即時雙聲道電平。設計稿:
// docs/worklogs/2026-08-23-playback/ui-mockup-v2.md(方案 4 + UI-27)。

/// 4pt 軌道 + 圓點;已播 MP.blue、未播 primary 8%(深色 16%);hover/拖曳時圓點
/// 10→14pt。點擊=跳到該處,拖曳=連續 seek(拖曳中只更新本地值,放開才送 Core,
/// 免得每個 mouse-move 都打 AVAudioPlayer.currentTime)。
struct PlaybackProgressBar: View {
    let time: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    /// 點「已播時間」=從頭播放(tooltip 也這麼說;三鏡頭審抓到原本只 seek(0)
    /// 在暫停中不會真的播,與 tooltip 承諾不符)。
    let onRestart: () -> Void
    /// UI-28b:算好的波形;nil=還沒算好或不可用 → 畫純軌道。兩種都佔同一個高度
    /// (waveHeight),替換時列高不跳(設計稿 v2 防閃爍條款)。
    var waveform: Waveform? = nil
    static let waveHeight: CGFloat = 34
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var dragFraction: Double? = nil

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }
    private var shownTime: TimeInterval { dragFraction.map { $0 * duration } ?? time }

    var body: some View {
        HStack(spacing: MP.spS) {
            Text(Self.clock(shownTime, style: duration))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .monospacedDigit()
                // 點「已播時間」=歸零(v2 次要捷徑;主要入口是右鍵「從頭播放」)。
                .contentShape(Rectangle())
                .onTapGesture { onRestart() }
                .help(L("從頭播放"))
            GeometryReader { geo in
                let w = geo.size.width
                let knob: CGFloat = (isHovering || dragFraction != nil) ? 14 : 10
                ZStack(alignment: .leading) {
                    if let waveform {
                        WaveformView(waveform: waveform, fraction: fraction, width: w)
                    } else {
                        Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.16 : 0.08)).frame(height: 4)
                        Capsule().fill(MP.blue).frame(width: max(0, w * fraction), height: 4)
                        Circle().fill(Color.white)
                            .overlay(Circle().stroke(MP.blue, lineWidth: 2))
                            .frame(width: knob, height: knob)
                            .offset(x: max(0, min(w - knob, w * fraction - knob / 2)))
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    }
                }
                .frame(height: Self.waveHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(1, max(0, v.location.x / max(1, w))) }
                        .onEnded { v in
                            let f = min(1, max(0, v.location.x / max(1, w)))
                            dragFraction = nil
                            onSeek(f * duration)
                        }
                )
                .animation(.easeOut(duration: 0.12), value: knob)
            }
            .frame(height: Self.waveHeight)
            .onHover { isHovering = $0 }
            Text(Self.clock(duration, style: duration))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // VoiceOver:進度列是 adjustable,值「已播 X 共 Y」,增減 5 秒(設計稿 v2)。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("播放進度"))
        .accessibilityValue(String(format: L("已播 %@,共 %@"), Self.spoken(shownTime), Self.spoken(duration)))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onSeek(min(duration, time + 5))
            case .decrement: onSeek(max(0, time - 5))
            @unknown default: break
            }
        }
    }

    /// m:ss;總長 ≥1 小時則兩邊都用 h:mm:ss(寬度一致,設計稿 v2)。
    static func clock(_ t: TimeInterval, style total: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    /// VoiceOver 用的口語時長,依 UI 語言在地化(「1 minute, 30 seconds」/「1分30秒」),
    /// 不用 m/s 縮寫(三鏡頭審)。
    @MainActor private static func spoken(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: Localizer.shared.localeIdentifier)
        f.calendar = cal
        f.unitsStyle = .full
        f.allowedUnits = t >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.zeroFormattingBehavior = .dropLeading
        return f.string(from: max(0, t)) ?? "\(Int(t))s"
    }
}

/// 列內短型即時電平:「對方 ▮▮▮▮▯▯▯▯  你 ▮▮▯▯▯▯▯▯」,各 8 段 5×7pt;標度與
/// 上方 LevelBar 相同(value 0…1 → 亮段數,>0.005 至少亮 1 段)。純裝飾,
/// VoiceOver 隱藏(資訊由進度列與主鈕提供,設計稿 v2 驗收條款)。
struct MiniLevelMeter: View {
    let label: String
    let value: Float
    let color: Color
    private static let segments = 8
    // 8 段線性下一般語音(−28 dBFS → value 0.16)只亮 1 段像沒聲音(2026-08-23 真檔實測);
    // 先改平方根,17:15 Eric 拍板三處統一真 dB 刻度(MeterScale):−28 dBFS → 5/8 段。
    private var lit: Int { MeterScale.segments(value, of: Self.segments) }
    var body: some View {
        HStack(spacing: MP.spXS) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < lit ? color : Color.primary.opacity(0.08))
                        .frame(width: 5, height: 7)
                }
            }
            .animation(.spring(duration: 0.15), value: lit)
        }
        .accessibilityHidden(true)
    }
}


/// UI-28b:雙聲道波形縮圖。上半=左=對方(珊瑚)、下半=右=你(藍);已播實色、未播
/// 35%;播放頭 1pt 線(深色白/淺色黑)。桶寬 2pt+間距 1pt,依可用寬度把 240 桶
/// 合併成 w/3 桶(320 窄版約 60 桶,非 Retina 不糊)。Canvas 一次畫完,10Hz 更新
/// 只重畫這一個 view。純裝飾:VoiceOver 由外層進度列的 adjustable 提供資訊。
struct WaveformView: View {
    let waveform: Waveform
    let fraction: Double
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme
    private static let bar: CGFloat = 2, gap: CGFloat = 1

    var body: some View {
        let n = max(8, min(waveform.bucketCount, Int(width / (Self.bar + Self.gap))))
        let wf = waveform.downsampled(to: n)
        Canvas { ctx, size in
            let mid = size.height / 2
            let half = mid - 1
            let step = size.width / CGFloat(n)
            let playedUpto = Int((fraction * Double(n)).rounded(.down))
            for i in 0..<n {
                let x = CGFloat(i) * step + (step - Self.bar) / 2
                let played = i < playedUpto
                let up = max(1, CGFloat(wf.left[i]) * half)
                let down = max(1, CGFloat(wf.right[i]) * half)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - up, width: Self.bar, height: up), cornerRadius: 1),
                         with: .color(MP.coral.opacity(played ? 1 : 0.35)))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid, width: Self.bar, height: down), cornerRadius: 1),
                         with: .color(MP.blue.opacity(played ? 1 : 0.35)))
            }
            let hx = min(size.width - 1, max(0, size.width * CGFloat(fraction)))
            ctx.fill(Path(CGRect(x: hx, y: 0, width: 1, height: size.height)),
                     with: .color(scheme == .dark ? .white : .black))
        }
        .accessibilityHidden(true)
    }
}
