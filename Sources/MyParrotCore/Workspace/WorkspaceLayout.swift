import Foundation

/// #2438 A1(UI-47):開關內容欄時視窗自動加寬／縮窄的純函式。
///
/// 規則(spec §11 A1):目標寬＝左欄＋Σ(間距＋欄寬);視窗左緣不動往右長;右緣超出可見區先整體左挪
/// (左緣不低於可見區左緣);還放不下就把各欄**等比**壓縮、各欄不低於 `minColumn`;壓到底仍放不下＝
/// 各欄取 `minColumn`、視窗寬＝可見區寬(內容欄會超出視窗,只在極窄螢幕發生)。高度與 y 不動但夾在
/// 可見區內;`openWidths` 空＝縮回只剩左欄。K1 控制欄在右邊時規則相同(新欄插在控制欄左側)。
/// `visible` 是視窗所在螢幕的可見區(AppKit `visibleFrame`,多螢幕時原點可非 0)。
public enum WorkspaceLayout {

    public static func resolve(current: CGRect, leftWidth: CGFloat = 380, gap: CGFloat = 10,
                               openWidths: [CGFloat], minColumn: CGFloat = 320,
                               visible: CGRect) -> (frame: CGRect, columnWidths: [CGFloat]) {
        let widths = openWidths.map { $0.isFinite ? max(0, $0) : minColumn }
        let target = total(leftWidth: leftWidth, gap: gap, columns: widths)
        guard visible.width > 0, visible.height > 0 else {
            return (CGRect(x: current.minX, y: current.minY, width: target, height: current.height), widths)
        }

        var columns = widths
        var width = target
        if target > visible.width {
            let room = visible.width - leftWidth - gap * CGFloat(widths.count)
            columns = compress(widths, toFit: room, floor: minColumn)
            width = total(leftWidth: leftWidth, gap: gap, columns: columns)
        }
        width = min(width, visible.width)

        var x = current.minX
        if x + width > visible.maxX { x = visible.maxX - width }
        x = max(x, visible.minX)

        let height = min(current.height, visible.height)
        let y = min(max(current.minY, visible.minY), visible.maxY - height)
        return (CGRect(x: x, y: y, width: width, height: height), columns)
    }

    /// 開著的欄全部釘在下限時的視窗寬(＝視窗最小寬度;UI-47 Eric 2026-10-19 23:40「縮小寬度沒抓最小值」)。
    public static func minimumWidth(leftWidth: CGFloat = 380, gap: CGFloat = 10, columns: Int, minColumn: CGFloat = 320) -> CGFloat {
        leftWidth + CGFloat(max(0, columns)) * (gap + minColumn)
    }

    /// 欄間把手(Eric 2026-10-19 23:42「在目前總視窗寬度內調整」):把手左邊那欄加 `dx`、右邊那欄減同樣的量,
    /// 兩欄都不低於 `floor`、總和不變;超出範圍就夾住。回傳(左, 右)的新寬(取整數點)。
    public static func redistribute(left: CGFloat, right: CGFloat, dx: CGFloat, floor: CGFloat = 320) -> (left: CGFloat, right: CGFloat) {
        let total = left + right
        guard total >= 2 * floor else { return (left, right) }          // 本來就放不下兩個下限:不動
        let newLeft = min(max(left + dx, floor), total - floor).rounded()
        return (newLeft, total - newLeft)
    }

    static func total(leftWidth: CGFloat, gap: CGFloat, columns: [CGFloat]) -> CGFloat {
        columns.reduce(leftWidth) { $0 + gap + $1 }
    }

    /// 等比壓縮到總和 ≤ `room`:同一比例縮各欄,縮到低於 `floor` 的欄釘在 `floor`、其餘重新分配
    /// (water-filling);壓縮後的寬度取整數點(往下取,總和不超出)。欄寬本來就 ≤ `floor` 的不動(壓縮不會把欄變寬)。
    /// 全部釘在下限仍超過 `room` ⇒ 回各欄下限。
    public static func compress(_ widths: [CGFloat], toFit room: CGFloat, floor: CGFloat) -> [CGFloat] {
        let floors = widths.map { min($0, floor) }
        guard room > floors.reduce(0, +) else { return floors }
        var result = widths
        var fixed = widths.map { $0 <= floor }
        while true {
            let fixedSum = widths.indices.filter { fixed[$0] }.reduce(CGFloat(0)) { $0 + result[$1] }
            let freeSum = widths.indices.filter { !fixed[$0] }.reduce(CGFloat(0)) { $0 + widths[$1] }
            guard freeSum > 0 else { break }
            let ratio = min(1, (room - fixedSum) / freeSum)
            var pinned = false
            for i in widths.indices where !fixed[i] && widths[i] * ratio < floor {
                fixed[i] = true
                result[i] = floor
                pinned = true
            }
            if !pinned {
                for i in widths.indices where !fixed[i] {
                    result[i] = max(floor, (widths[i] * ratio).rounded(.down))
                }
                break
            }
        }
        return result
    }
}
