import Foundation

/// #2438 T3 逐字稿實時翻譯(實驗,Phase 3 才有實作:Apple Translation framework、llama.cpp GGUF)。
/// 只加一行譯文、原文不動;Core 只認這個 protocol,不 import 任何 SDK、不含端點。
/// 回傳陣列與 `lines` 一一對應(同長度、同順序)。
public protocol TranslationProvider: Sendable {
    func translate(_ lines: [String], from: Locale.Language, to: Locale.Language) async throws -> [String]
}
