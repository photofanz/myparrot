import Foundation
import ArgumentParser

/// `@main` + 子命令註冊 + 無子命令時的雙軌分派(§4.2,D2)。
@main
struct MyParrot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "myparrot",
        abstract: "本機開會錄音+即時逐字稿 CLI——agent 友善子命令(軌 A)與互動選單(軌 B)雙軌並存",
        discussion: """
        不帶子命令執行:TTY(人用終端)→ 進互動選單;非 TTY(pipe/agent)→ 印 help 後 exit 0,\
        絕不掛著等輸入。
        """,
        subcommands: [
            RecordCommand.self, StopCommand.self, StatusCommand.self,
            TranscribeCommand.self, ListCommand.self, DevicesCommand.self,
            ConfigCommand.self, HooksCommand.self,
            CLISelfTestCommand.self   // 隱藏:CLI-01/02 純函式回歸(shouldDisplay=false,不進 --help)
        ]
    )

    /// 只有「沒有匹配到任何子命令」時 ArgumentParser 才會呼叫這裡(§4.2,
    /// D2 雙軌分派)。
    mutating func run() async throws {
        if Output.isStdinTTY && Output.isStdoutTTY {
            await InteractiveMenu.run()
        } else {
            print(MyParrot.helpMessage())
        }
        MPExitCode.success.terminate()
    }
}
