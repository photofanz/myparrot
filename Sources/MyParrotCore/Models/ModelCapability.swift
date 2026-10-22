import Foundation

/// #2438 T3 多模型架構(MDL-01):app 內可以呼叫模型的能力,**只有這三個**(CLAUDE.md 產品邊界例外)。
/// 每個能力各自一個 protocol(`CorrectionProvider`／`MinutesProvider`／`TranslationProvider`),
/// 各自在設定頁選後端;Core 只認 protocol,不 import 任何 SDK、不含任何端點。
public enum ModelCapability: String, CaseIterable, Sendable, Codable {
    case correction, minutes, translation
}

/// 後端描述(登錄表的一列):`id` 進 UserDefaults(`model.<能力>`);`isLocal` 決定要不要跳隱私確認框。
public struct ModelBackendInfo: Sendable, Identifiable, Equatable {
    /// "off"／"claudeCLI"／"localFake"(DEBUG)／將來 "appleFM" "ggufLocal" …
    public let id: String
    /// l10n key(App 層 `L(label)`;字串在 `ModelBackendRegistry` 的 l10n-keys 標記區段)。
    public let label: String
    /// 這個後端宣告支援的能力;`backends(for:)` 依此過濾。
    public let capabilities: Set<ModelCapability>
    /// true＝資料不出這台電腦、不跳隱私確認框。
    public let isLocal: Bool
    /// true＝只在 DEBUG 建置提供(假供應商;release 選單不列,MDL-01/04)。
    public let debugOnly: Bool

    public init(id: String, label: String, capabilities: Set<ModelCapability>, isLocal: Bool, debugOnly: Bool = false) {
        self.id = id
        self.label = label
        self.capabilities = capabilities
        self.isLocal = isLocal
        self.debugOnly = debugOnly
    }
}
