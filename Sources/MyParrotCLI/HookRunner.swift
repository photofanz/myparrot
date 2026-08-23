import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// hook 執行器(§8,D6)。模板替換、子進程(新進程組)、timeout/killpg、產物驗證、
/// fallback/strict 語意。純函式部分(模板替換/timeout 計算)獨立成 static func
/// 方便 CLI-01 SelfTest 表驅動。
enum HookRunner {

    /// `{audio}/{transcript}/{name}/{dir}` 模板替換(純函式,SelfTest)。
    static func substitute(_ template: String, audio: String, transcript: String?,
                            name: String, dir: String) -> String {
        template
            .replacingOccurrences(of: "{audio}", with: audio)
            .replacingOccurrences(of: "{transcript}", with: transcript ?? "")
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{dir}", with: dir)
    }

    /// hook 執行環境變數(env 雙軌之一;另一軌=stdin JSON)。
    static func environment(audio: String, transcript: String?, name: String, dir: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MYPARROT_AUDIO"] = audio
        env["MYPARROT_TRANSCRIPT"] = transcript ?? ""
        env["MYPARROT_NAME"] = name
        env["MYPARROT_DIR"] = dir
        env["MYPARROT_CHANNEL_LEFT"] = "對方"
        env["MYPARROT_CHANNEL_RIGHT"] = "你"
        return env
    }

    /// stdin 餵的 metadata JSON(完整版,給要讀更多欄位的複雜 hook)。
    static func stdinMetadataJSON(stage: String, audio: String, transcript: String?, name: String, dir: String) -> Data {
        let json = JSONLine.encode([
            "stage": stage, "audio": audio, "transcript": transcript, "name": name, "dir": dir,
            "channelLeft": "對方", "channelRight": "你"
        ])
        return Data(json.utf8)
    }

    struct RunOutcome: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var launchError: String?
    }

    /// 實際起子進程、餵 env/stdin、逾時 killpg。回傳原始結果(exit code/輸出/是
    /// 否逾時);「成功判定」(產物驗證)是呼叫端的事(§8:exit 0 不等於成功)。
    static func execute(command: String, cwd: String?, env: [String: String],
                         stdinData: Data, timeoutSec: Double?) async -> RunOutcome {
        await Task.detached(priority: .userInitiated) {
            runBlocking(command: command, cwd: cwd, env: env, stdinData: stdinData, timeoutSec: timeoutSec)
        }.value
    }

    /// 阻塞版本——刻意用 Thread(而非 Task/DispatchQueue 的 @Sendable 閉包)做
    /// stdout/stderr 併發讀取跟 timeout 監看,繞開 Swift 6 嚴格併發檢查對這種
    /// 「短命輔助執行緒、資料只在同一個函式內流動」場景的過度限制,寫法對照
    /// 既有 Core 的 `@unchecked Sendable` 慣例(WhisperCppFileProvider 等)。
    private static func runBlocking(command: String, cwd: String?, env: [String: String],
                                     stdinData: Data, timeoutSec: Double?) -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let cwd, !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: expandTilde(cwd)) }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return RunOutcome(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: "\(error)")
        }

        let pid = process.processIdentifier
        // 新進程組:pgid=自己的 pid,timeout 才能 killpg 到整組(含 hook 自己起
        // 的子進程,如 whisper-cli)。setpgid 在子進程 exec 前呼叫才保證有效;
        // 這裡緊接在 run() 之後呼叫,race window 極短(見 notes.md 取捨紀錄)。
        setpgid(pid, pid)

        stdinPipe.fileHandleForWriting.write(stdinData)
        try? stdinPipe.fileHandleForWriting.close()

        let outBox = DataBox()
        let errBox = DataBox()
        let outThread = Thread { outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
        let errThread = Thread { errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile() }
        outThread.start()
        errThread.start()

        let timedOutBox = FlagBox()
        if let timeoutSec {
            let watchdog = Thread {
                Thread.sleep(forTimeInterval: timeoutSec)
                guard kill(pid_t(pid), 0) == 0 else { return }   // 已結束,不用管
                timedOutBox.flag = true
                killpg(pid_t(pid), SIGTERM)
                Thread.sleep(forTimeInterval: 5)
                if kill(pid_t(pid), 0) == 0 { killpg(pid_t(pid), SIGKILL) }
            }
            watchdog.start()
        }

        process.waitUntilExit()
        while !outThread.isFinished || !errThread.isFinished {
            Thread.sleep(forTimeInterval: 0.01)
        }

        return RunOutcome(exitCode: process.terminationStatus,
                          stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                          stderr: String(data: errBox.data, encoding: .utf8) ?? "",
                          timedOut: timedOutBox.flag,
                          launchError: nil)
    }

    /// hook 產物驗證(防靜默失敗,D6):exit 0 **且**(`{base}.txt` 存在非空 或
    /// stdout 末行 JSON 帶 `transcript` 路徑且該檔存在非空)才算成功。
    /// 純函式(給定 outcome + 檔案存在性判斷閉包),SelfTest 可注入假檔案系統。
    static func transcribeHookSucceeded(exitCode: Int32, stdout: String, expectedTxtPath: String,
                                        fileExistsNonEmpty: (String) -> Bool) -> (ok: Bool, transcriptPath: String?) {
        guard exitCode == 0 else { return (false, nil) }
        if fileExistsNonEmpty(expectedTxtPath) { return (true, expectedTxtPath) }
        if let lastLine = stdout.split(separator: "\n").last,
           let data = lastLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = obj["transcript"] as? String,
           fileExistsNonEmpty(path) {
            return (true, path)
        }
        return (false, nil)
    }
}

/// 短命輔助執行緒間傳資料用的簡單盒子——`@unchecked Sendable` 是刻意的:資料
/// 只在單一 `runBlocking` 呼叫的生命週期內、由該函式自己協調的執行緒存取,
/// 沒有跨呼叫共用,比照 Core 既有慣例(見 WhisperCppFileProvider.swift)。
final class DataBox: @unchecked Sendable {
    var data = Data()
}

final class FlagBox: @unchecked Sendable {
    var flag = false
}
