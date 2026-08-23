import Foundation
import ArgumentParser
import MyParrotCore

/// `myparrot transcribe <file.m4a>`(§7)。走跟 GUI「轉逐字稿」按鈕完全相同的
/// `RecordingController.transcribe(_:)` 路徑(同引擎選擇、同 sidecar 契約),不
/// 直接碰 Core 的 file provider 型別(那些是 internal,CLI 模組本來就拿不到)。
struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcribe", abstract: "轉錄一個既有的錄音檔")

    @Argument(help: "音檔路徑(.m4a/.caf)") var file: String
    @Option(name: .long, help: "逐字稿引擎:apple|whisper") var engine: String?
    @Flag(name: .long, help: "輸出單行 JSON 結果") var json = false

    @MainActor
    mutating func run() async throws {
        let path = expandTilde(file)
        guard FileManager.default.fileExists(atPath: path) else {
            Output.errLine("找不到檔案:\(path)")
            MPExitCode.argumentError.terminate()
        }
        if let engine, resolveEngineFlag(engine) == nil {
            Output.errLine("錯誤:--engine 只接受 apple|whisper,收到「\(engine)」")
            MPExitCode.argumentError.terminate()
        }

        let config = CLIConfigStore.load()
        let controller = RecordingController()
        controller.engine = resolveEngine(engine ?? config.engine)
        if let langRaw = config.language, let lang = parseLanguage(langRaw) { controller.language = lang }

        let url = URL(fileURLWithPath: path)
        let rec = Recording(id: UUID(), title: url.deletingPathExtension().lastPathComponent,
                            url: url, date: Date(), duration: 0, hasTranscript: false)
        controller.transcribe(rec)
        while controller.isTranscribing {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let base = url.deletingPathExtension()
        let txt = base.appendingPathExtension("txt").path
        let srt = base.appendingPathExtension("srt").path
        let txtOK = (try? FileManager.default.attributesOfItem(atPath: txt)[.size] as? UInt64).flatMap { $0 } ?? 0 > 0
        if let err = controller.lastError, !txtOK {
            if json { Output.jsonEvent(["event": "transcribed", "error": err]) }
            else { Output.errLine("轉逐字稿失敗:\(err)") }
            MPExitCode.transcriptionFailed.terminate()
        }
        let srtExists = FileManager.default.fileExists(atPath: srt)
        if json {
            Output.jsonEvent(["event": "transcribed", "transcript": txt, "srt": srtExists ? srt : nil,
                              "engine": controller.engine.rawValue])
        } else {
            Output.infoLine("逐字稿:\(txt)")
            if srtExists { Output.infoLine("SRT:\(srt)") }
        }
    }
}
