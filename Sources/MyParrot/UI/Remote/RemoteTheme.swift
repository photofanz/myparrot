import SwiftUI
import AppKit
import CoreText

/// #2438 UI v2 遙控器的材質 tokens(spec §2:C1 霓虹 LED 環、Q1 黑曜石玻璃、R1 Share Tech Mono)。
/// 深色＝Eric 拍板的 mockup.html(黑曜石圓盤、石墨圓鍵);淺色＝Eric 2026-10-20 A1「銀色鋁合金」
/// (`remote-light-options.html` 方案 1:拉絲銀板身、銀色內凹外盤、緞面銀中心鍵、銀圓鍵黑字,LED 環嵌在銀盤凹槽,
/// 計時與鍵名改成深色印刷字)。顏色一律走 NSColor dynamicProvider 依外觀切換;只有陰影／高光的不透明度與發光
/// 在 view 端看 `colorScheme`(淺色不發光、不壓黑)。
enum RemoteTheme {
    private static func rgb(_ v: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
    static func color(_ v: UInt32, alpha: Double = 1) -> Color {
        let c = rgb(v)
        return Color(red: c.0, green: c.1, blue: c.2, opacity: alpha)
    }
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamicAlpha(light: (light, 1), dark: (dark, 1))
    }
    private static func dynamicAlpha(light: (UInt32, Double), dark: (UInt32, Double)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (v, a) = isDark ? dark : light
            let c = rgb(v)
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: a)
        }))
    }

    // 板身:淺＝拉絲銀三段(mockup --slabA/B 改 #eeefec→#dfe0dc→#d3d4d0),深＝石墨(#3c3f3c→#242624)
    static let slabTop = dynamic(light: 0xEEEFEC, dark: 0x3C3F3C)
    static let slabMid = dynamic(light: 0xDFE0DC, dark: 0x2F322F)
    static let slabBottom = dynamic(light: 0xD3D4D0, dark: 0x242624)
    static let slabEdge = dynamicAlpha(light: (0x000000, 0.20), dark: (0xFFFFFF, 0.14))
    /// 藥丸底(--inset)
    static let pillFill = Color.primary.opacity(0.055)

    // 圓鍵格:淺＝銀鍵黑字,深＝石墨鍵亮字
    static let keyTop = dynamic(light: 0xF8F9F6, dark: 0x4C4F4C)
    static let keyMid = dynamic(light: 0xE4E5E1, dark: 0x3F423F)
    static let keyBottom = dynamic(light: 0xD2D3CF, dark: 0x333633)
    static let keyFg = dynamic(light: 0x1D1F1D, dark: 0xE8EAE5)
    static let keyLabel = dynamic(light: 0x4D514D, dark: 0xA3A8A3)
    static let keyRim = dynamicAlpha(light: (0x000000, 0.16), dark: (0x000000, 0.55))

    // 外盤:淺＝銀色內凹(#e3e4e0→#cfd0cb→#bfc0bb),深＝深色玻璃(#30342f→#202320→#161816)
    static let dialOuterA = dynamic(light: 0xE3E4E0, dark: 0x30342F)
    static let dialOuterB = dynamic(light: 0xCFD0CB, dark: 0x202320)
    static let dialOuterC = dynamic(light: 0xBFC0BB, dark: 0x161816)
    static let dialRim = dynamicAlpha(light: (0x000000, 0.16), dark: (0x000000, 0.30))
    /// LED 環未亮段(淺色＝銀盤上的淡灰刻度,深色＝近黑)
    static let ringBg = dynamic(light: 0xC3C4BF, dark: 0x2C2E2C)
    static let ledOther = color(0xFF7A4A)
    static let ledYou = color(0x5FB4FF)
    static let ledHot = color(0xFFB020)

    // 中央:淺＝緞面銀瓷(#fbfbf9→#e9eae6→#d7d8d3),深＝黑曜石(Q1)
    static let obsidianA = dynamic(light: 0xFBFBF9, dark: 0x4E524E)
    static let obsidianB = dynamic(light: 0xE9EAE6, dark: 0x2A2D2A)
    static let obsidianC = dynamic(light: 0xD7D8D3, dark: 0x151615)
    static let timerIdle = dynamic(light: 0x1D1F1D, dark: 0xF1F2EE)
    static let timerRecording = dynamic(light: 0xB03A30, dark: 0xFF9D8E)
    static let timerPaused = dynamic(light: 0xB8761A, dark: 0xFFCF7A)
    static let recordGlyph = dynamic(light: 0xC8372D, dark: 0xFF6B5B)
    static let plusGlyph = dynamic(light: 0x3A3D3A, dark: 0xDFE3DC)
    static let keyText = dynamic(light: 0x1D1F1D, dark: 0xEEF0EA)
    static let stopText = dynamic(light: 0xA32D2D, dark: 0xFFA394)
    static let pulseRed = color(0xDC463C)

    // 扇形鍵三層漸層(暫停／繼續 與 結束),按下的兩層,接縫線與接縫旁亮線
    static let sectorA = dynamic(light: 0xF6F6F3, dark: 0x4B504B)
    static let sectorB = dynamic(light: 0xE2E3DF, dark: 0x2E322E)
    static let sectorC = dynamic(light: 0xCFD0CB, dark: 0x191B19)
    static let sectorStopA = dynamic(light: 0xF8E9E5, dark: 0x5A3F3A)
    static let sectorStopB = dynamic(light: 0xEFD3CC, dark: 0x3A2724)
    static let sectorStopC = dynamic(light: 0xE2BDB4, dark: 0x1D1514)
    static let sectorPressedA = dynamic(light: 0xC9CAC5, dark: 0x171917)
    static let sectorPressedB = dynamic(light: 0xD8D9D4, dark: 0x222422)
    static let seam = dynamicAlpha(light: (0x000000, 0.22), dark: (0x000000, 0.85))
    static let seamHighlight = dynamicAlpha(light: (0xFFFFFF, 0.80), dark: (0xFFFFFF, 0.06))
}

/// R1:Share Tech Mono(OFL)打包在 app bundle 的 Resources/Fonts,啟動時註冊到 process 範圍;
/// 缺檔(`swift run` 開發模式、打包時沒放)回落 SF Mono,只印一行不擋。
@MainActor
enum FontRegistrar {
    static let shareTechMono = "ShareTechMono-Regular"
    private(set) static var registered = false

    static func registerBundledFonts() {
        guard let res = Bundle.main.resourceURL else { return }
        let dir = res.appendingPathComponent("Fonts")
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension.lowercased() == "ttf" {
                var err: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                    let why = err?.takeRetainedValue().localizedDescription ?? "?"
                    print("[FONT] 註冊失敗 \(url.lastPathComponent): \(why)")
                }
            }
        }
        registered = NSFont(name: shareTechMono, size: 12) != nil
        if !registered { print("[FONT] Share Tech Mono 不可用(Resources/Fonts 缺檔?),計時字型回落 SF Mono") }
    }
}
