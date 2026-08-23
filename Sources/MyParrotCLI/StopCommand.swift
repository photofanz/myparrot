import Foundation
import ArgumentParser
#if canImport(Darwin)
import Darwin
#endif

/// `myparrot stop`(§5)。讀 pidfile → SIGINT → 等優雅收尾。**絕不 SIGKILL**
/// (ffmpeg moov atom / CAF finalize 損檔教訓,decisions D2)。
struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "結束目前的錄音(送 SIGINT,等收尾)")

    @Flag(name: .long, help: "額外等到後製(轉檔/轉錄/hook)完全結束才回傳(上限 30 分)") var wait = false
    @Flag(name: .long, help: "輸出單行 JSON 結果") var json = false

    func run() async throws {
        guard let pid = StateStore.activePID() else {
            if json { Output.jsonEvent(["recording": false, "message": "沒有進行中的錄音"]) }
            else { Output.infoLine("沒有進行中的錄音") }
            MPExitCode.success.terminate()
        }

        guard kill(pid_t(pid), SIGINT) == 0 else {
            Output.errLine("送出 SIGINT 給 pid \(pid) 失敗:\(String(cString: strerror(errno)))")
            MPExitCode.recordingFailed.terminate()
        }

        // 等 pidfile/state 消失(=錄音進程正常結束並自行清檔),逾時警告但絕不強殺。
        let stopDeadline = Date().addingTimeInterval(15)
        while StateStore.activePID() != nil, Date() < stopDeadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if StateStore.activePID() != nil {
            Output.errLine("⚠ 已送出停止訊號,但 15 秒內未看到收尾完成(pidfile 仍在)——錄音可能還在做較長的收尾,請稍候用 `myparrot status` 確認,不會強殺進程")
            if !wait {
                if json { Output.jsonEvent(["recording": true, "message": "停止訊號已送出,收尾中"]) }
                MPExitCode.recordingFailed.terminate()
            }
        }

        if wait {
            // 額外等到 state 檔(postprocessing)整個消失——上限 30 分。
            let waitDeadline = Date().addingTimeInterval(30 * 60)
            while StateStore.readState() != nil, Date() < waitDeadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        if json { Output.jsonEvent(["recording": false, "message": "已停止"]) }
        else { Output.infoLine("已停止") }
        MPExitCode.success.terminate()
    }
}

/// `myparrot status`(§5)。無 pidfile/stale → `{"recording":false}`;有 → state
/// 檔全文 + `"recording":true"`。
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "目前有沒有在錄音、錄多久、電平快照")

    @Flag(name: .long, help: "輸出 JSON(預設也是 JSON——status 天生是給 agent 讀的)") var json = false

    func run() throws {
        guard let pid = StateStore.activePID(), let state = StateStore.readState() else {
            Output.jsonEvent(["recording": false])
            return
        }
        Output.jsonEvent([
            "recording": true, "pid": Int(pid), "startedAt": state.startedAt,
            "audioPath": state.audioPath, "name": state.name, "state": state.state,
            "other": state.levels.other, "you": state.levels.you,
            "otherSignal": state.levels.otherSignal, "youSignal": state.levels.youSignal,
            "warning": state.warning, "updatedAt": state.updatedAt
        ])
    }
}
