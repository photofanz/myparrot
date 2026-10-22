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
        // #949:建 controller 時就指定資料夾(init 會掃＋收割;不先掃偏好裡的舊資料夾)。
        let controller = RecordingController(recordingsDir: resolvedRecordingsDir(config))
        // #949 REC-32:init 的收割端把租約已死的 inprogress 復原成頂層「-已修復」檔 ⇒ 每場一個 `recovered` 事件。
        // 走 stderr(--json 時 stdout 要維持單一 JSON 陣列,不能混進事件行)。
        let recoveredPaths = Set(controller.recoveredRecordings.map(\.url.path))
        for r in controller.recoveredRecordings {
            if json {
                FileHandle.standardError.write(Data((JSONLine.encode(["event": "recovered", "sessionId": r.sessionId,
                                                                       "audioPath": r.url.path]) + "\n").utf8))
            } else {
                Output.errLine("已復原中斷的錄音:\(r.url.path)")
            }
        }
        // 剛復原的那幾場正在轉 m4a:等轉完(上限 120 秒)再列,列出來的才是最終路徑。
        if !recoveredPaths.isEmpty {
            let deadline = Date().addingTimeInterval(120)
            while controller.recordings.contains(where: { $0.isConverting }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        // 收割過程的錯誤(太短進隔離區、讀不到租約 fail closed、復原 rename 失敗)一律講出來,不吞。
        if let err = controller.lastError { Output.errLine(err) }

        if json {
            let items = controller.recordings.map { rec -> [String: Any?] in
                ["title": rec.title, "path": rec.url.path, "date": ISO8601.string(rec.date),
                 "durationSec": rec.duration, "hasTranscript": rec.hasTranscript, "isConverting": rec.isConverting,
                 "needsManualRepair": rec.needsManualRepair,
                 "recovered": rec.title.hasSuffix(Recording.repairedSuffix) ? true : nil]
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
