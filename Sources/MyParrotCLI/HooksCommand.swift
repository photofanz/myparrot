import Foundation
import ArgumentParser
import AVFoundation

/// `myparrot hooks [approve|run]`(§8,D6,Phase 5)。hook 執行引擎本身
/// (`HookRunner`/`HookTrust`)是共用基礎,record 流程從 Phase 1 就在用;這支
/// 檔案只放命令列介面(核准/手動觸發)。
struct HooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks", abstract: "hook 管理(trust-on-first-use 核准/手動觸發)",
        subcommands: [HooksApproveCommand.self, HooksRunCommand.self]
    )
}

struct HooksApproveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve", abstract: "核准目前 config 的 hooks 段(trust-on-first-use)")

    func run() throws {
        let config = CLIConfigStore.load()
        guard let hooks = config.hooks, !hooks.isEmpty else {
            Output.infoLine("config 目前沒有設定任何 hooks")
            return
        }
        try HookTrust.approve(hooks)
        Output.infoLine("已核准 \(hooks.count) 個 hook(s)")
    }
}

struct HooksRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "對任意檔手動觸發 hook(無視 auto,仍驗 trust)")

    @Argument(help: "transcribe|minutes") var stage: String
    @Argument(help: "音檔路徑") var file: String
    @Flag(name: .long, help: "輸出 JSON") var json = false

    mutating func run() async throws {
        guard ["transcribe", "minutes"].contains(stage) else {
            Output.errLine("stage 只接受 transcribe|minutes")
            MPExitCode.argumentError.terminate()
        }
        let path = expandTilde(file)
        guard FileManager.default.fileExists(atPath: path) else {
            Output.errLine("找不到檔案:\(path)")
            MPExitCode.argumentError.terminate()
        }
        let config = CLIConfigStore.load()
        guard let hook = config.hooks?[stage] else {
            Output.errLine("config 沒有設定 \(stage) hook")
            MPExitCode.argumentError.terminate()
        }
        guard HookTrust.isApproved(config.hooks) else {
            Output.errLine("hooks 尚未核准,先執行 myparrot hooks approve")
            MPExitCode.argumentError.terminate()
        }

        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension()
        let txt = base.appendingPathExtension("txt").path
        let transcript = stage == "minutes" ? (FileManager.default.fileExists(atPath: txt) ? txt : nil) : nil
        let dir = url.deletingLastPathComponent().path
        let name = url.deletingPathExtension().lastPathComponent
        let command = HookRunner.substitute(hook.command, audio: path, transcript: transcript, name: name, dir: dir)
        let env = HookRunner.environment(audio: path, transcript: transcript, name: name, dir: dir)
        let stdinData = HookRunner.stdinMetadataJSON(stage: stage, audio: path, transcript: transcript, name: name, dir: dir)
        let audioLenSec: Double = (try? AVAudioFile(forReading: url)).flatMap { f in
            f.processingFormat.sampleRate > 0 ? Double(f.length) / f.processingFormat.sampleRate : nil
        } ?? 0
        let timeout = hook.timeout.resolvedSeconds(audioDurationSec: audioLenSec)

        let outcome = await HookRunner.execute(command: command, cwd: hook.cwd, env: env,
                                               stdinData: stdinData, timeoutSec: timeout)
        let ok = outcome.exitCode == 0 && !outcome.timedOut && outcome.launchError == nil
        let detail = ok ? nil : (outcome.launchError ?? "exit \(outcome.exitCode);stderr:\(outcome.stderr.prefix(200))")
        if json {
            Output.jsonEvent(["event": "hook", "stage": stage,
                              "status": ok ? "ok" : (outcome.timedOut ? "timeout" : "failed"), "detail": detail])
        } else if ok {
            Output.infoLine("hook 執行成功")
        } else {
            Output.errLine("hook 執行失敗:\(detail ?? "")")
        }
        if !ok {
            (hook.strict ? MPExitCode.hookFailedStrict : MPExitCode.transcriptionFailed).terminate()
        }
    }
}
