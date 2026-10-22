import Foundation

/// BUG-31(2026-10-17,Eric 目擊):UI-25 記住的標準模式 frame 可能是接外接螢幕時存的(x=1685),
/// 回到只有 MacBook 螢幕(1512 寬)時 `setFrame` 照套,AppKit 只保證留一小條可抓 ⇒ 視窗卡在螢幕邊緣只露 40 pt。
/// 純函式:frame 有 ≥ 一半面積落在任一現有螢幕的可見區就原樣用;否則搬進主螢幕可見區(保留大小,
/// 太大就縮到主螢幕可見區;原點夾進去,右/上超出就貼邊)。
public enum WindowFrameClamp {
    public static func clamp(_ frame: CGRect, screens: [CGRect], primary: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let area = frame.width * frame.height
        for s in screens {
            let i = frame.intersection(s)
            if !i.isNull, i.width * i.height >= area * 0.5 { return frame }
        }
        guard primary.width > 0, primary.height > 0 else { return frame }
        let w = min(frame.width, primary.width)
        let h = min(frame.height, primary.height)
        let x = min(max(frame.minX, primary.minX), primary.maxX - w)
        let y = min(max(frame.minY, primary.minY), primary.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
