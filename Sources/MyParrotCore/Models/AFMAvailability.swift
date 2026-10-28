import Foundation
#if canImport(FoundationModels) && !MYPARROT_NO_AFM
import FoundationModels
#endif

/// #2438 Phase 3a(AFM-01):Apple Foundation Models 可用性。Core 只給狀態列舉與 l10n key,文字在 App 層 `L()`。
/// `probe()` 便宜且同步:macOS < 26 ⇒ `.unsupportedOS`(不碰框架);否則讀 `SystemLanguageModel.default.availability`。
public enum AFMStatus: Equatable, Sendable {
    case available
    case unavailable(AFMReason)
    case unsupportedOS
}

public enum AFMReason: String, Sendable, CaseIterable {
    case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unknown
}

public enum AFMAvailability {
    /// DEBUG 驗證用覆寫(`myparrotctl afm force`):有值時 `probe()` 直接回它。release 不會被設。
    nonisolated(unsafe) public static var debugOverride: AFMStatus?

    /// 這台 OS 有沒有 FoundationModels(macOS 26+);`MYPARROT_NO_AFM` 建置(CLT-05)一律假 ⇒ 登錄表不列 appleFM。
    public static var isPlatformSupported: Bool {
        #if canImport(FoundationModels) && !MYPARROT_NO_AFM
        if #available(macOS 26, *) { return true } else { return false }
        #else
        return false
        #endif
    }

    public static func probe() -> AFMStatus {
        if let o = debugOverride { return o }
        #if canImport(FoundationModels) && !MYPARROT_NO_AFM
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
                case .modelNotReady: return .unavailable(.modelNotReady)
                @unknown default: return .unavailable(.unknown)
                }
            }
        }
        #endif
        return .unsupportedOS
    }

    /// 給 UI 的 l10n key(純函式,可測);available ⇒ nil。
    public static func messageKey(for status: AFMStatus) -> String? {
        // l10n-keys:begin
        switch status {
        case .available: return nil
        case .unsupportedOS: return "Apple 本機模型需要 macOS 26 以上"
        case .unavailable(.deviceNotEligible): return "這台 Mac 不支援 Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence 尚未開啟:系統設定 → Apple Intelligence 與 Siri"
        case .unavailable(.modelNotReady): return "Apple 模型尚未就緒:請確認 Siri 語言與系統語言相同、Apple Intelligence 已開啟;模型可能還在下載"
        case .unavailable(.unknown): return "Apple 本機模型目前無法使用"
        }
        // l10n-keys:end
    }
}
