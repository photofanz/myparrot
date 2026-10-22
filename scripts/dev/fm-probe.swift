// Apple Foundation Models 可用性探針(#2438 Phase 3 前置;2026-10-20 查「為什麼 macOS 27 還不能用」)。
// 編譯:DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O scripts/dev/fm-probe.swift -o /tmp/fm-probe && /tmp/fm-probe
// 只讀不寫:印 SystemLanguageModel.default 的 availability 與原因、支援語言、目前語系。
// 配合看:plutil -p /var/db/eligibilityd/eligibility.plist | grep -A 28 GREYMATTER(資格域;DEVICE_AND_SIRI_LANGUAGE_MATCH=2 就是裝置語言≠Siri 語言)
//        python3 讀 ~/Library/Preferences/com.apple.gms.availability.plist 的 enhancedSiri.unifiedReasons(JSON:notOptedIn / selectedSiriLanguageIneligible / pendingEnrollment)
import Foundation
import FoundationModels

let m = SystemLanguageModel.default
switch m.availability {
case .available: print("availability: available")
case .unavailable(let r):
    switch r {
    case .deviceNotEligible: print("availability: unavailable(deviceNotEligible)")
    case .appleIntelligenceNotEnabled: print("availability: unavailable(appleIntelligenceNotEnabled)")
    case .modelNotReady: print("availability: unavailable(modelNotReady)")
    @unknown default: print("availability: unavailable(unknown: \(r))")
    }
}
print("isAvailable:", m.isAvailable)
print("supportedLanguages:", m.supportedLanguages.map { $0.maximalIdentifier }.sorted().joined(separator: ", "))
let zh = Locale.Language(identifier: "zh-Hant")
print("supports zh-Hant:", m.supportsLocale(Locale(identifier: "zh-Hant_TW")))
print("current locale:", Locale.current.identifier, "preferred:", Locale.preferredLanguages.prefix(3).joined(separator: ","))
