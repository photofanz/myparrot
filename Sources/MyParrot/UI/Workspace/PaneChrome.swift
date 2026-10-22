import SwiftUI
import AppKit
import MyParrotCore

/// #2438 M4:三個內容欄的 UI 屬性(圖示、名稱、主色、快捷鍵)。主色取 mockup `.tg.on`:
/// 逐字稿＝藍、筆記＝珊瑚、會議記錄＝綠(`--ok #2f9e5b`)。
extension PaneKind {
    /// SF Symbol 線框版;開著時由 `.symbolVariant(.fill)` 換實心(`note.text` 沒有 fill 版會自動退回線框)。
    var symbol: String {
        switch self {
        case .transcript: return "text.bubble"
        case .notes: return "note.text"
        case .minutes: return "list.clipboard"
        }
    }

    @MainActor var title: String {
        switch self {
        case .transcript: return L("逐字稿")
        case .notes: return L("筆記")
        case .minutes: return L("會議記錄")
        }
    }

    var tint: Color {
        switch self {
        case .transcript: return MP.blue
        case .notes: return MP.coral
        case .minutes: return Color(red: 0.184, green: 0.620, blue: 0.357)
        }
    }

    /// I1:⌘2／⌘3／⌘4(選單 `AppCommands` 掛真的快捷鍵;這裡只給 tooltip)。
    var shortcut: String {
        switch self {
        case .transcript: return "⌘2"
        case .notes: return "⌘3"
        case .minutes: return "⌘4"
        }
    }
}

/// 直欄與檔案面板共用的卡片底(mockup `.pane`:--card 白卡在 --win 灰底上、細邊、圓角 10)。純色 fill、無 `.shadow`。
struct PaneCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MP.paneCard))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// B2:遙控器狀態藥丸右側的面板開關圖示(逐字稿／筆記／會議記錄;會議記錄只在後端 ≠ off 時出現)。
/// 開＝實心＋該欄主色＋淡色底 chip;關＝線框 `.secondary`。窄版／迷你沒有直欄 ⇒ 圖示全顯示成關、
/// 變暗 .38 不可按(跟圓鍵格「不可用變暗不消失」同一套語言)。紅點(關著有新內容)Phase 1 先不做。
struct PaneToggleIcons: View {
    @Bindable var uiState: AppUIState
    /// 標準模式才可開關。
    let enabled: Bool
    @State private var loc = Localizer.shared

    private var kinds: [PaneKind] {
        uiState.minutesEnabled ? [.transcript, .notes, .minutes] : [.transcript, .notes]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds, id: \.self) { kind in
                let on = enabled && uiState.panes.open.contains(kind)
                Button { uiState.panes.toggle(kind) } label: {
                    Image(systemName: kind.symbol)
                        .symbolVariant(on ? .fill : .none)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? kind.tint : Color.secondary)
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? kind.tint.opacity(0.16) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.38)
                .help("\(kind.title) \(kind.shortcut)")
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 一個內容直欄:標題列(`⋮⋮` 拖曳換位、圖示、名稱、該欄自己的控制、◀ ▶、×)＋內容。
/// 換位與停靠的放下處理在 `WorkspaceView`(整欄都是放下目標)。
struct PaneContainer<Controls: View, Content: View>: View {
    let kind: PaneKind
    @Bindable var uiState: AppUIState
    let canMoveLeft: Bool
    let canMoveRight: Bool
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let content: () -> Content
    @State private var loc = Localizer.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
            content()
                .padding(MP.spS)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .modifier(PaneCardStyle())
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("⋮⋮").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 14, height: 22).contentShape(Rectangle())
                .pointerStyle(.grabIdle)
                .onDrag {
                    uiState.dragPayload = kind.rawValue
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .help(L("拖曳換位"))
                .accessibilityLabel(L("拖曳換位"))
            Image(systemName: kind.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(kind.tint)
            Text(kind.title).font(MPFont.label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            controls()
            HStack(spacing: 0) {
                chromeButton("arrowtriangle.left.fill", size: 8, help: L("往左移"), enabled: canMoveLeft) {
                    uiState.panes.move(kind, by: -1, minutesEnabled: uiState.minutesEnabled)
                }
                chromeButton("arrowtriangle.right.fill", size: 8, help: L("往右移"), enabled: canMoveRight) {
                    uiState.panes.move(kind, by: 1, minutesEnabled: uiState.minutesEnabled)
                }
            }
            chromeButton("xmark", size: 10, help: "\(L("關閉面板")) \(kind.shortcut)", enabled: true) {
                uiState.panes.toggle(kind)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func chromeButton(_ symbol: String, size: CGFloat, help: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(.tertiary)
                .frame(width: 16, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 欄間把手(寬＝欄間距 10pt):拖曳改**左側**那欄的寬度(最小 320);放開才寫偏好(呼叫端處理)。
/// 位移量用螢幕座標的滑鼠位置算——拖曳中視窗會跟著加寬／左挪,view 自己的座標系在動,不能拿手勢的 translation。
struct ColumnResizeHandle: View {
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    @State private var startX: CGFloat?
    @State private var hovering = false
    @State private var loc = Localizer.shared

    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(width: WorkspaceView.gap)
            .frame(maxHeight: .infinity)
            .overlay(Capsule().fill(Color.primary.opacity(hovering || startX != nil ? 0.35 : 0.12))
                .frame(width: 3, height: 36))
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        let x = NSEvent.mouseLocation.x
                        if startX == nil { startX = x; onBegin() }
                        onChange(x - (startX ?? x))
                    }
                    .onEnded { _ in
                        let x = NSEvent.mouseLocation.x
                        let dx = x - (startX ?? x)
                        startX = nil
                        onEnd(dx)
                    }
            )
            .help(L("調整欄寬"))
            .accessibilityLabel(L("調整欄寬"))
    }
}
