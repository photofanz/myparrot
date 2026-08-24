import AppKit
import Foundation

// Draws the MyParrot app icon: a chibi parrot wearing headphones (matches the
// in-app mascot). build-app.sh / iconutil turn the .iconset into .icns.

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
    }
    // coordinates use a 32x32 space, y measured from TOP
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x/32*s, y: s - y/32*s) }
    func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: (cx-rx)/32*s, y: s-(cy+ry)/32*s, width: 2*rx/32*s, height: 2*ry/32*s)).fill()
    }
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) { oval(cx, cy, r, r, c) }
    func rrect(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rad: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: (cx-w/2)/32*s, y: s-(cy+h/2)/32*s, width: w/32*s, height: h/32*s),
                     xRadius: rad/32*s, yRadius: rad/32*s).fill()
    }
    func tri(_ a: NSPoint, _ b: NSPoint, _ cc: NSPoint, _ c: NSColor) {
        c.setFill(); let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.line(to: cc); p.close(); p.fill()
    }
    func band(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ lw: CGFloat, _ c: NSColor) {
        c.setStroke()
        let p = NSBezierPath()
        p.appendArc(withCenter: NSPoint(x: cx/32*s, y: s - cy/32*s), radius: rad/32*s, startAngle: 18, endAngle: 162)
        p.lineWidth = lw/32*s; p.lineCapStyle = .round; p.stroke()
    }

    let blue = col(55, 138, 221)
    let dark = col(40, 40, 38)

    // background: rounded square, light blue
    col(230, 241, 251).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s*0.22, yRadius: s*0.22).fill()

    // body + belly
    oval(16, 21, 9, 10, blue)
    oval(16, 23, 5.5, 7, col(181, 212, 245))
    // crest feathers
    tri(P(13, 2.5), P(15.5, 8), P(10.5, 8), col(239, 159, 39))
    tri(P(17, 2), P(19.5, 8), P(14.5, 8), col(186, 117, 23))
    // head
    circle(16, 12, 8, blue)
    // eyes
    circle(13, 11.5, 2, .white); circle(13.4, 11.8, 1, col(4, 44, 83))
    circle(19, 11.5, 2, .white); circle(18.6, 11.8, 1, col(4, 44, 83))
    // beak (apex down)
    tri(P(14.3, 14), P(17.7, 14), P(16, 18), col(216, 90, 48))
    // headphones: band + ear cups
    band(16, 12, 10, 1.8, dark)
    rrect(6.8, 13, 3, 5, 1.3, dark)
    rrect(25.2, 13, 3, 5, 1.3, dark)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// UI-31(2026-08-24,Eric 拍板 A-1):有 master PNG(AI 美術)就走「圓角淺藍底＋置中貼圖」,
// 沒有就回落原本的程式化畫鸚鵡——美術檔遺失時 build 仍可組,不會空 icon。
// master 需透明背景;佔畫布 86%(inset 7%),等比置中。
func drawMaster(size: Int, master: NSImage) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx
    ctx?.imageInterpolation = .high
    NSColor(srgbRed: 230/255, green: 241/255, blue: 251/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: s * 0.22, yRadius: s * 0.22).fill()
    let inset = s * 0.07
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let msz = master.size
    if msz.width > 0, msz.height > 0 {
        let scale = min(box.width / msz.width, box.height / msz.height)
        let dw = msz.width * scale, dh = msz.height * scale
        master.draw(in: NSRect(x: box.midX - dw / 2, y: box.midY - dh / 2, width: dw, height: dh),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let masterPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/icon-master.png"
let master = NSImage(contentsOfFile: masterPath)

// 二審(2026-08-24):不吞錯——目錄建不起來/寫檔失敗/產出驗不過一律 stderr + 非零退出,
// 否則磁碟滿/路徑不可寫時仍印「寫到…」,可能封出缺圖示的包。
func die(_ msg: String) -> Never {
    FileHandle.standardError.write("❌ make-icon:\(msg)\n".data(using: .utf8)!)
    exit(1)
}
do {
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
} catch {
    die("建立 iconset 目錄失敗:\(error)")
}

// 二審(2026-08-24 both):master「檔案存在但壞掉」=錯誤直接 die,不是靜默 fallback
// (fallback 只留給檔案不存在的開發模式);驗解碼、尺寸、alpha、四角透明
// (四角不透明=疑似白底未去背,貼上圓角底會出方形白邊)。
if FileManager.default.fileExists(atPath: masterPath) {
    guard let m = master, let tiff = m.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
        die("master 存在但無法解碼或尺寸為 0:\(masterPath)")
    }
    guard rep.hasAlpha else { die("master 需透明背景(無 alpha 通道):\(masterPath)") }
    let mw = rep.pixelsWide, mh = rep.pixelsHigh
    for (x, y) in [(0, 0), (mw - 1, 0), (0, mh - 1), (mw - 1, mh - 1)] {
        if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 {
            die("master 四角不透明(疑似白底未去背):\(masterPath)")
        }
    }
}

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in specs {
    guard let data = master.flatMap({ drawMaster(size: size, master: $0) }) ?? draw(size: size) else {
        die("\(name) 繪製失敗(size \(size))")
    }
    do {
        try data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    } catch {
        die("\(name) 寫檔失敗:\(error)")
    }
}
// 完整性驗證:10 檔皆存在、可解碼、像素尺寸正確。
for (size, name) in specs {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(out)/\(name)")),
          let rep = NSBitmapImageRep(data: data), rep.pixelsWide == size, rep.pixelsHigh == size else {
        die("\(name) 產出驗證失敗(缺檔/不可解碼/尺寸不符 \(size))")
    }
}
// 二審(both):內容檢查——走 master 路徑時,最大尺寸圖需有足量「非底色」像素,
// 攔「master 沒畫上去、只有淺藍底」這類尺寸正確的假成功(64×64 取樣,門檻 5%)。
if master != nil {
    let p = "\(out)/icon_512x512@2x.png"
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)), let rep = NSBitmapImageRep(data: d) else {
        die("內容檢查讀不到 icon_512x512@2x.png")
    }
    var diff = 0
    let grid = 64
    for i in 0..<grid { for j in 0..<grid {
        let x = i * rep.pixelsWide / grid, y = j * rep.pixelsHigh / grid
        if let c = rep.colorAt(x: x, y: y) {
            let dr = abs(c.redComponent - 230.0 / 255), dg = abs(c.greenComponent - 241.0 / 255)
            let db = abs(c.blueComponent - 251.0 / 255)
            if dr + dg + db > 0.15 { diff += 1 }
        }
    } }
    if diff < grid * grid / 20 {
        die("產出疑似純底色(非底色取樣 \(diff)/\(grid * grid) < 5%) — master 內容沒畫上去?")
    }
}
print("iconset 寫到 \(out)\(master != nil ? "(master: \(masterPath))" : "(程式化 fallback)"),10 尺寸驗證通過")
