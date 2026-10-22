import Foundation
import MyParrotCore

/// BUG-28(#1680):錄音中警示橫幅的在地化。繁中原文與參數都由 Core 決定
/// (`RecordingWarning.template` / `arguments`),這裡只負責查表與填值——
/// 裝置名是系統給的字串不翻,原因與「系統預設」是繁中 key 要翻。
@MainActor extension RecordingWarning {
    var localized: String {
        let args = arguments.map { arg -> String in
            switch arg {
            case .raw(let text):    return text
            case .localizable(let key): return L(key)
            }
        }
        return Lf(template, args)
    }
}
