import Foundation
import MyParrotCore

/// `~/.config/myparrot/record.pid` + `state.json`(§2.2,§2.3)。
/// #949 第一段:實作搬進 Core(`Sources/MyParrotCore/Recording/RecordingStateFile.swift`),
/// GUI 當 owner 時也要寫同一個 state.json;CLI 既有呼叫點以 typealias 沿用舊名,零改動。
typealias CLIRecordingState = RecordingStateFile
typealias StateStore = RecordingStateStore
typealias AtomicFile = MyParrotCore.AtomicFile
typealias ISO8601 = MyParrotCore.ISO8601
