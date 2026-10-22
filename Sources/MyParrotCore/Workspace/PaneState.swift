import Foundation

/// #2438 面板工作區(UI-45/46):右側內容欄的種類。預設順序 逐字稿 → 筆記 → 會議記錄。
public enum PaneKind: String, CaseIterable, Codable, Sendable {
    case transcript, notes, minutes
}

/// K1:控制欄(遙控器＋檔案列表)只能停靠最左或最右;內容欄永遠在中間。
public enum RemoteSide: String, CaseIterable, Codable, Sendable {
    case left, right
}

/// 面板工作區的狀態(純值;偏好 JSON 由 App 層存取)。
/// - `open`:哪些內容欄開著。會議記錄欄另受 B2 約束:後端 off 時視同關(`visibleColumns(minutesEnabled:)`),偏好保留。
/// - `order`:三個內容欄的完整順序(關著的也在裡面,重開回原位)。
/// - `widths`:使用者拉過的欄寬;沒拉過＝`defaultColumnWidth`。
public struct PaneState: Equatable, Sendable {
    public var open: Set<PaneKind>
    public var order: [PaneKind]
    public var remoteSide: RemoteSide
    public var widths: [PaneKind: CGFloat]
    /// 既有 `listExpanded`(左欄檔案列表展開)搬進來。
    public var filesExpanded: Bool

    public static let defaultColumnWidth: CGFloat = 380
    public static let minColumnWidth: CGFloat = 320
    public static let defaultOrder: [PaneKind] = [.transcript, .notes, .minutes]

    public init(open: Set<PaneKind>, order: [PaneKind] = PaneState.defaultOrder, remoteSide: RemoteSide = .left,
                widths: [PaneKind: CGFloat] = [:], filesExpanded: Bool = true) {
        self.open = open
        self.order = PaneState.normalizedOrder(order)
        self.remoteSide = remoteSide
        self.widths = widths.filter { $0.value.isFinite && $0.value > 0 }
        self.filesExpanded = filesExpanded
    }

    /// 標準模式預設:開 逐字稿＋筆記。
    public static let standard = PaneState(open: [.transcript, .notes])
    /// 窄版預設:直欄全關(只剩左欄)。
    public static let compact = PaneState(open: [])

    // MARK: 開關

    public mutating func toggle(_ kind: PaneKind) {
        if open.contains(kind) { open.remove(kind) } else { open.insert(kind) }
    }

    /// 畫面上實際顯示的內容欄(依 `order`)。B2:會議記錄後端 off ⇒ 會議記錄欄視同關。
    public func visibleColumns(minutesEnabled: Bool) -> [PaneKind] {
        order.filter { open.contains($0) && ($0 != .minutes || minutesEnabled) }
    }

    // MARK: 換位(UI-46)

    /// 把 `kind` 往右(+)／往左(−)移 `delta` 格,**以畫面上看得到的欄為準**(關著的欄不佔格,
    /// 否則 ◀ ▶ 會換到看不見的欄、畫面沒變化);兩端夾住、越界不動。`kind` 本身沒顯示時改在完整順序裡移。
    /// 關著的欄維持彼此的相對位置。
    public mutating func move(_ kind: PaneKind, by delta: Int, minutesEnabled: Bool = true) {
        order = PaneState.normalizedOrder(order)
        guard delta != 0 else { return }
        var lane = visibleColumns(minutesEnabled: minutesEnabled)
        if !lane.contains(kind) { lane = order }
        guard let i = lane.firstIndex(of: kind) else { return }
        let j = min(max(i + delta, 0), lane.count - 1)
        guard j != i else { return }
        let anchor = lane[j]
        order.removeAll { $0 == kind }
        guard let a = order.firstIndex(of: anchor) else { return }
        order.insert(kind, at: delta > 0 ? a + 1 : a)
    }

    // MARK: 停靠(K1)

    public mutating func dock(_ side: RemoteSide) { remoteSide = side }

    /// 拖曳控制欄放下時以視窗中線判定換邊:放在中線左邊＝左、右邊＝右、正好在中線＝不動。
    /// `dropX` 是視窗內座標(0…windowWidth)。
    public mutating func dock(dropX: CGFloat, windowWidth: CGFloat) {
        let mid = windowWidth / 2
        if dropX < mid { remoteSide = .left } else if dropX > mid { remoteSide = .right }
    }

    // MARK: 欄寬

    public func width(of kind: PaneKind) -> CGFloat { widths[kind] ?? PaneState.defaultColumnWidth }

    /// 使用者拉欄寬:不低於 `minimum`。
    public mutating func setWidth(_ w: CGFloat, for kind: PaneKind, minimum: CGFloat = PaneState.minColumnWidth) {
        guard w.isFinite else { return }
        widths[kind] = max(minimum, w)
    }

    /// 給 `WorkspaceLayout.resolve` 的 `openWidths`(顯示中各欄,依畫面順序)。
    public func openWidths(minutesEnabled: Bool) -> [CGFloat] {
        visibleColumns(minutesEnabled: minutesEnabled).map(width(of:))
    }

    // MARK: 正規化

    /// 去重(留第一次出現)、補齊缺的種類(依預設順序接在後面)。
    public static func normalizedOrder(_ order: [PaneKind]) -> [PaneKind] {
        var out: [PaneKind] = []
        for k in order where !out.contains(k) { out.append(k) }
        for k in defaultOrder where !out.contains(k) { out.append(k) }
        return out
    }
}

/// 偏好 JSON(`panes.standard`／`panes.compact`):寫出時欄位順序固定;讀入時容忍缺欄位、不認得的種類
/// (較新版本寫的)與重複——缺的回標準預設、不認得的丟掉、順序補齊。型別不對才丟錯(App 層回預設並印一行)。
extension PaneState: Codable {
    private enum CodingKeys: String, CodingKey { case open, order, remoteSide, widths, filesExpanded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = PaneState.standard
        let openRaw = try c.decodeIfPresent([String].self, forKey: .open)
        let orderRaw = try c.decodeIfPresent([String].self, forKey: .order)
        let sideRaw = try c.decodeIfPresent(String.self, forKey: .remoteSide)
        let widthsRaw = try c.decodeIfPresent([String: CGFloat].self, forKey: .widths)
        let files = try c.decodeIfPresent(Bool.self, forKey: .filesExpanded)
        var widths: [PaneKind: CGFloat] = [:]
        for (k, v) in widthsRaw ?? [:] { if let kind = PaneKind(rawValue: k) { widths[kind] = v } }
        self.init(open: openRaw.map { Set($0.compactMap(PaneKind.init(rawValue:))) } ?? base.open,
                  order: orderRaw.map { $0.compactMap(PaneKind.init(rawValue:)) } ?? base.order,
                  remoteSide: sideRaw.flatMap(RemoteSide.init(rawValue:)) ?? base.remoteSide,
                  widths: widths,
                  filesExpanded: files ?? base.filesExpanded)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PaneKind.allCases.filter(open.contains).map(\.rawValue), forKey: .open)
        try c.encode(order.map(\.rawValue), forKey: .order)
        try c.encode(remoteSide.rawValue, forKey: .remoteSide)
        var w: [String: CGFloat] = [:]
        for (k, v) in widths { w[k.rawValue] = v }
        try c.encode(w, forKey: .widths)
        try c.encode(filesExpanded, forKey: .filesExpanded)
    }
}
