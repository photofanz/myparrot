import SwiftUI

/// MyParrot mascot — a chibi parrot wearing headphones. While recording it
/// "sings": beak opens/closes, music notes float up, the head bobs, and
/// sound-wave rings pulse. Idle = still.
/// UI-32(2026-08-24):尊重系統「減少動態效果」——開啟時不啟動任何 repeatForever
/// 動畫、藏聲波/音符,錄音狀態改由靜止姿勢與其他 UI(紅點/狀態列)傳達。
struct ParrotMascot: View {
    var size: CGFloat = 58
    var isRecording: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false
    @State private var ring = false
    @State private var sing = false
    @State private var notes = false

    private var s: CGFloat { size }

    /// UI-32:PNG 幀模式——app bundle 的 Resources/mascot/{idle,sing}.png
    /// (idle=收翅閉嘴/sing=張翅張嘴;錄音中輪替=拍翅+唱歌,UI-33b Eric 2026-08-24 06:32)。
    /// 沒有資產(swift run 開發模式、美術未到)回落既有向量畫法;載一次全程共用。
    /// internal:adBar 的迷你 logo 共用(UI-33)。
    static let pngFrames: (idle: NSImage, sing: NSImage)? = {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("mascot")
        guard let idle = NSImage(contentsOf: dir.appendingPathComponent("idle.png")),
              let sing = NSImage(contentsOf: dir.appendingPathComponent("sing.png")) else { return nil }
        return (idle, sing)
    }()

    /// UI-33b:footer 用的大頭小圖(與 app icon 同美術,16pt 才辨識得出;全身縮
    /// 16pt 糊成一團)。缺檔回落 idle 幀→🦜(RootView 端處理)。
    static let headIcon: NSImage? = {
        guard let res = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: res.appendingPathComponent("mascot/head.png"))
    }()

    var body: some View {
        ZStack {
            if isRecording && !reduceMotion { rings }
            character
                .rotationEffect(.degrees(isRecording && bob ? 3 : -3))
                .offset(y: isRecording && bob ? -s * 0.03 : 0)
            if isRecording && !reduceMotion { musicNotes }
        }
        .frame(width: s, height: s)
        .onAppear { if !reduceMotion { startAnimations() } }
        .onChange(of: reduceMotion) { _, rm in
            if rm {
                // 立即停:值改回靜止,且不帶動畫(中斷 repeatForever)。
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { bob = false; ring = false; sing = false; notes = false }
            } else {
                startAnimations()
            }
        }
    }

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { bob = true }
        withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) { ring = true }
        withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) { sing = true }
        withAnimation(.easeIn(duration: 1.25).repeatForever(autoreverses: false)) { notes = true }
    }

    /// PNG 幀優先,無資產回落向量 parrot。
    /// 換幀不能靠 withAnimation 的布林(布林不可插值,repeatForever 對「離散的
    /// 圖片切換」無效——設成 true 後就停住,嘴一直張著不動;Eric 2026-08-24 06:06
    /// 真機抓到)。改 TimelineView 定時驅動,錄音中每 0.35s 開合一次。
    @ViewBuilder private var character: some View {
        if let f = Self.pngFrames {
            if isRecording && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
                    let open = Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 2 == 0
                    frameImage(open ? f.sing : f.idle)
                }
            } else {
                frameImage(f.idle)
            }
        } else {
            parrot
        }
    }

    private func frameImage(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: s, height: s)
    }

    // Pulsing sound-wave rings while recording.
    private var rings: some View {
        ZStack {
            Circle().stroke(MP.blue, lineWidth: 2).frame(width: s * 0.7, height: s * 0.7)
                .scaleEffect(ring ? 1.5 : 0.5).opacity(ring ? 0 : 0.5)
            Circle().stroke(MP.coral, lineWidth: 2).frame(width: s * 0.7, height: s * 0.7)
                .scaleEffect(ring ? 1.35 : 0.5).opacity(ring ? 0 : 0.4)
        }
    }

    // ♪ ♫ rising from the beak and fading.
    private var musicNotes: some View {
        ZStack {
            Text("♪").font(.system(size: s * 0.22, weight: .bold)).foregroundStyle(MP.coral)
                .offset(x: s * 0.30, y: notes ? -s * 0.42 : -s * 0.02).opacity(notes ? 0 : 0.95)
            Text("♫").font(.system(size: s * 0.18, weight: .bold)).foregroundStyle(MP.blue)
                .offset(x: s * 0.42, y: notes ? -s * 0.52 : s * 0.02).opacity(notes ? 0 : 0.85)
        }
    }

    private var parrot: some View {
        ZStack {
            Ellipse().fill(MP.blue).frame(width: s * 0.58, height: s * 0.64).offset(y: s * 0.14)
            Ellipse().fill(Color(red: 0.71, green: 0.83, blue: 0.96))
                .frame(width: s * 0.32, height: s * 0.42).offset(y: s * 0.18)
            // crest
            Triangle().fill(Color(red: 0.937, green: 0.624, blue: 0.153))
                .frame(width: s * 0.12, height: s * 0.16).offset(x: -s * 0.05, y: -s * 0.40)
            Triangle().fill(Color(red: 0.729, green: 0.459, blue: 0.090))
                .frame(width: s * 0.12, height: s * 0.16).offset(x: s * 0.05, y: -s * 0.40)
            // head
            Circle().fill(MP.blue).frame(width: s * 0.56, height: s * 0.56).offset(y: -s * 0.16)
            // eyes
            eye(dx: -s * 0.12)
            eye(dx: s * 0.12)
            // beak: upper fixed, lower drops open while singing
            BeakTri().fill(MP.coral).frame(width: s * 0.16, height: s * 0.12).offset(y: -s * 0.05)
            BeakTri().fill(Color(red: 0.66, green: 0.27, blue: 0.13))
                .frame(width: s * 0.14, height: s * 0.10).rotationEffect(.degrees(180))
                .offset(y: (isRecording && sing) ? s * 0.06 : -s * 0.005)
            // headphones
            Band().stroke(headphone, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                .frame(width: s * 0.62, height: s * 0.2).offset(y: -s * 0.30)
            earCup(dx: -s * 0.30)
            earCup(dx: s * 0.30)
        }
    }

    private var headphone: Color { Color(red: 0.17, green: 0.17, blue: 0.16) }

    private func eye(dx: CGFloat) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: s * 0.14, height: s * 0.14)
            Circle().fill(Color(red: 0.016, green: 0.173, blue: 0.325)).frame(width: s * 0.07, height: s * 0.07)
        }.offset(x: dx, y: -s * 0.18)
    }

    private func earCup(dx: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.04).fill(headphone)
            .frame(width: s * 0.1, height: s * 0.16).offset(x: dx, y: -s * 0.14)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Downward-pointing beak triangle.
private struct BeakTri: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Headphone band: an arch from bottom-left over the top to bottom-right.
private struct Band: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.4))
        return p
    }
}
