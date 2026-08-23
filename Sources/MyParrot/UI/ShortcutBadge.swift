import SwiftUI

/// UI-24: small monospace capsule printing a keyboard shortcut *inside* the
/// control it belongs to — same Button, same border, never floating next to
/// it (design v3 hard rule: "快捷鍵膠囊一律在所屬控制項邊框內").
/// Symbols (⌘R 等) are locale-invariant → no L() call needed here.
/// Hidden from VoiceOver: the owning Button carries its own accessibilityLabel
/// with the function name only, and `.keyboardShortcut()` gives assistive tech
/// the real shortcut metadata — see `mpShortcut` below.
struct ShortcutBadge: View {
    let symbol: String
    /// true inside the red primary buttons (開始/結束) — same-hue pale tint
    /// instead of the neutral pill, so it reads on the red background.
    var onAccent: Bool = false

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(onAccent ? Color.white.opacity(0.20) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(onAccent ? Color.white.opacity(0.38) : Color.primary.opacity(0.18), lineWidth: 0.5)
            )
            .foregroundStyle(onAccent ? Color.white.opacity(0.92) : Color.secondary)
            // VoiceOver 不念膠囊(v3 定稿)——快捷鍵資訊由 .keyboardShortcut() 提供,
            // 功能名由外層 Button 的 accessibilityLabel 提供。
            .accessibilityHidden(true)
    }
}

extension View {
    /// Attach ⌘+key only when a shortcut is supplied — lets call sites pass
    /// `nil` for states where a control exists but has no assigned shortcut
    /// (e.g. 新錄音 while paused — only the finished-state occurrence carries ⌘N).
    @ViewBuilder
    func mpShortcut(_ char: Character?) -> some View {
        if let char {
            self.keyboardShortcut(KeyEquivalent(char), modifiers: .command)
        } else {
            self
        }
    }
}
