import Foundation
import Observation
import MyParrotCore

/// #2438 Phase 3a(AFM-01):App 層的 Apple Foundation Models 可用性單例。何時檢查:第一個視窗前、app 回前景、
/// 設定頁開啟、每次會議記錄更新與建校正 provider 前;全部走 `refresh()`,🚫 不另起輪詢。
/// DEBUG `myparrotctl afm force <reason>` 寫 Core 的 `AFMAvailability.debugOverride`,校正與會議記錄兩條路都看得到。
@MainActor
@Observable
final class AppleFMAvailability {
    static let shared = AppleFMAvailability()

    private(set) var status: AFMStatus = .unsupportedOS
    private(set) var checkedAt: Date?

    func refresh() {
        status = AFMAvailability.probe()
        checkedAt = Date()
    }

    var isAvailable: Bool { status == .available }

    /// 給 UI 的字串;可用 ⇒ nil。
    var message: String? { AFMAvailability.messageKey(for: status).map { L($0) } }

    /// 這台 OS 有沒有這個後端可選(macOS 26+)。
    var isPlatformSupported: Bool { AFMAvailability.isPlatformSupported }

    #if DEBUG
    var forced: AFMStatus? {
        get { AFMAvailability.debugOverride }
        set { AFMAvailability.debugOverride = newValue; refresh() }
    }
    #endif
}
