import Foundation
import ArgumentParser
import MyParrotCore

/// `myparrot list`(§7)。掃 recordingsDir——直接借用 `RecordingController` 的
/// `recordings`(loadRecordings() 在 init 就跑過),資料形與 GUI 列表同一份。
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "列出最近的錄音")

    @Flag(name: .long, help: "輸出 JSON") var json = false

    @MainActor
    func run() async throws {
        let config = CLIConfigStore.load()
        let controller = RecordingController()
        controller.setRecordingsDir(resolvedRecordingsDir(config))

        if json {
            let items = controller.recordings.map { rec -> [String: Any?] in
                ["title": rec.title, "path": rec.url.path, "date": ISO8601.string(rec.date),
                 "durationSec": rec.duration, "hasTranscript": rec.hasTranscript, "isConverting": rec.isConverting]
            }
            let lines = items.map { JSONLine.encode($0) }
            print("[" + lines.joined(separator: ",") + "]")
            return
        }
        if controller.recordings.isEmpty {
            Output.infoLine("(沒有錄音:\(controller.recordingsDir.path))")
            return
        }
        for rec in controller.recordings {
            let mins = Int(rec.duration) / 60
            let secs = Int(rec.duration) % 60
            let flag = rec.isConverting ? "[處理中]" : (rec.hasTranscript ? "[已有逐字稿]" : "")
            Output.infoLine(String(format: "%@ %3d:%02d  %@ %@", dateLabel(rec.date), mins, secs, rec.title, flag))
        }
    }

    private func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// `myparrot devices`(§7)。標記沿 GUI micLabel 同語意(藍牙⚠️/iPhone)。
struct DevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "列出可用的輸入裝置(麥克風)")

    @Flag(name: .long, help: "輸出 JSON") var json = false

    func run() throws {
        let devices = AudioDevices.inputDevices()
        if json {
            let items = devices.map { d -> [String: Any?] in
                ["id": Int(d.id), "uid": d.uid, "name": d.name, "isBluetooth": d.isBluetooth,
                 "isBuiltIn": d.isBuiltIn, "isContinuity": d.isContinuity]
            }
            let lines = items.map { JSONLine.encode($0) }
            print("[" + lines.joined(separator: ",") + "]")
            return
        }
        if devices.isEmpty { Output.infoLine("(找不到輸入裝置)"); return }
        for d in devices {
            Output.infoLine("- \(MicPicker.label(for: d))  (uid=\(d.uid))")
        }
    }
}
