import Foundation
import MyParrotCore
#if canImport(Darwin)
import Darwin
#endif

/// 軌 B 互動選單(§9,D2)。`myparrot` 不帶子命令、且 stdin/stdout 皆 TTY 時進入。
/// 跟軌 A(RecordCommand)共用同一套 Core 引擎與 pidfile/state 檔——外部
/// `myparrot stop`/`status` 對互動中的 session 一樣有效。
///
/// **與 RecordCommand 的關係(取捨紀錄)**:互動模式的錄音畫面/後製流程跟
/// `RecordCommand`概念相同,但多了 termios raw mode 單鍵(p/Enter/m)與「auto:
/// false 的 hook 要現場問要不要跑」(D6)這兩個 agent 情境不需要的互動行為,
/// 兩邊各自寫一份(而非硬拆一個共用 engine)——時間成本考量下的務實選擇,
/// 兩邊都各自有 CLI-01/CLI-11 覆蓋,行為分岔風險記在 notes.md「還能怎麼優化」。
@MainActor
enum InteractiveMenu {

    private static let mainMenuItems = [
        "新錄音(輸入會議名稱 → 開始)",
        "最近錄音(列表 → 轉逐字稿/顯示路徑)",
        "設定(麥克風/引擎/辨識語言/自動轉錄/hook 狀態)"
    ]

    static func run() async {
        while true {
            var config = CLIConfigStore.load()
            let dir = resolvedRecordingsDir(config)
            Output.infoLine("")
            let header = "🦜 MyParrot        錄音目錄: \(dir.path)\n(↑↓ 選擇,Enter/數字確認,q/Esc 離開)"
            // 修 3:TTY 時優先方向鍵導覽;`tcsetattr` 失敗(理論上這裡必為
            // TTY——`InteractiveMenu.run()` 只會在 `MyParrotCLI.run()` 已確認
            // stdin/stdout 皆 TTY 才被呼叫,但仍保留防呆)才 fallback 回原本
            // `readLine()` 編號輸入,非 TTY 行為完全不受影響。
            if let outcome = ArrowMenu.select(title: header, items: mainMenuItems) {
                switch outcome {
                case .index(0): await newRecordingFlow(config: &config)
                case .index(1): await recentRecordingsFlow(config: config)
                case .index(2): await settingsFlow(config: &config)
                case .cancelled: return
                default: break
                }
                continue
            }
            Output.infoLine("🦜 MyParrot        錄音目錄: \(dir.path)")
            Output.infoLine("1. 新錄音(輸入會議名稱 → 開始)")
            Output.infoLine("2. 最近錄音(列表 → 轉逐字稿/顯示路徑)")
            Output.infoLine("3. 設定(麥克風/引擎/辨識語言/自動轉錄/hook 狀態)")
            Output.infoLine("q. 離開")
            Output.infoLine("> ", terminator: "")
            guard let choice = readLine() else { return }   // EOF(如 echo "" | myparrot 管入)→ 直接結束,不掛住
            switch choice.trimmingCharacters(in: .whitespaces) {
            case "1": await newRecordingFlow(config: &config)
            case "2": await recentRecordingsFlow(config: config)
            case "3": await settingsFlow(config: &config)
            case "q", "Q": return
            default: Output.infoLine("(無效選擇)")
            }
        }
    }

    // MARK: - 1. 新錄音

    private static func newRecordingFlow(config: inout CLIConfigSchema) async {
        Output.infoLine("會議名稱(Enter=「錄音」):")
        let name = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if let active = StateStore.activePID() {
            Output.errLine("已有錄音進行中(pid \(active)),請先用 myparrot stop 或到那個畫面結束")
            return
        }
        // #949:GUI(或另一個新版 CLI)持有全域租約 ⇒ 不開第二份。
        if case .alive(let lease) = RecordingLeaseHolder.inspect() {
            Output.errLine(lease.owner == "gui"
                ? guiRecordingRefusal(name: lease.name, elapsed: externalElapsed(lease))
                : "已有錄音進行中(pid \(lease.pid)),請先用 myparrot stop 或到那個畫面結束")
            return
        }
        let session = InteractiveRecordingSession(recordingsDir: resolvedRecordingsDir(config))
        await session.run(name: name, config: &config)
    }

    // MARK: - 2. 最近錄音

    private static func recentRecordingsFlow(config: CLIConfigSchema) async {
        let controller = RecordingController(recordingsDir: resolvedRecordingsDir(config))
        let recs = controller.recordings
        guard !recs.isEmpty else { Output.infoLine("(沒有錄音)"); return }

        let recItems = recs.map { r -> String in
            let flag = r.isConverting ? "[處理中]" : (r.hasTranscript ? "[已有逐字稿]" : "")
            return flag.isEmpty ? r.title : "\(r.title) \(flag)"
        }
        let rec: Recording
        if let outcome = ArrowMenu.select(title: "最近錄音(↑↓ 選擇,Enter/數字確認,q/Esc 返回):", items: recItems) {
            switch outcome {
            case .index(let idx): rec = recs[idx]
            case .cancelled: return
            }
        } else {
            Output.infoLine("最近錄音:")
            for (i, r) in recs.enumerated() {
                let flag = r.isConverting ? "[處理中]" : (r.hasTranscript ? "[已有逐字稿]" : "")
                Output.infoLine("\(i + 1). \(r.title) \(flag)")
            }
            Output.infoLine("選編號(Enter=返回):")
            guard let raw = readLine(), let idx = Int(raw.trimmingCharacters(in: .whitespaces)),
                  idx >= 1, idx <= recs.count else { return }
            rec = recs[idx - 1]
        }

        let actionItems = ["轉逐字稿", "執行後製 hook(minutes)", "顯示路徑"]
        let action: String
        if let outcome = ArrowMenu.select(title: "選動作(↑↓ 選擇,Enter/數字確認,q/Esc 返回):", items: actionItems) {
            switch outcome {
            case .index(let idx): action = String(idx + 1)
            case .cancelled: return
            }
        } else {
            Output.infoLine("1. 轉逐字稿  2. 執行後製 hook(minutes)  3. 顯示路徑")
            guard let a = readLine()?.trimmingCharacters(in: .whitespaces) else { return }
            action = a
        }
        switch action {
        case "1":
            controller.transcribe(rec)
            while controller.isTranscribing { try? await Task.sleep(nanoseconds: 300_000_000) }
            if let err = controller.lastError { Output.errLine("失敗:\(err)") }
            else { Output.infoLine("完成:\(rec.url.deletingPathExtension().appendingPathExtension("txt").path)") }
        case "2":
            guard let hook = config.hooks?["minutes"] else { Output.errLine("config 沒有設定 minutes hook"); return }
            guard HookTrust.isApproved(config.hooks) else { Output.errLine("hooks 尚未核准,先在終端跑 myparrot hooks approve"); return }
            let base = rec.url.deletingPathExtension()
            let txt = base.appendingPathExtension("txt").path
            let transcript = FileManager.default.fileExists(atPath: txt) ? txt : nil
            let outcome = await runHook(hook, stage: "minutes", audio: rec.url.path,
                                        transcript: transcript, name: rec.title,
                                        dir: rec.url.deletingLastPathComponent().path, elapsed: rec.duration)
            Output.infoLine(outcome.exitCode == 0 && !outcome.timedOut ? "hook 執行成功" : "hook 執行失敗:exit \(outcome.exitCode)")
        case "3":
            Output.infoLine(rec.url.path)
        default: break
        }
    }

    // MARK: - 3. 設定

    private static func settingsFlow(config: inout CLIConfigSchema) async {
        let items = ["麥克風", "引擎", "語言", "自動轉錄開關(目前:\(config.autoTranscribe ?? true))"]
        let choice: String
        if let outcome = ArrowMenu.select(title: "設定(↑↓ 選擇,Enter/數字確認,q/Esc 返回):", items: items) {
            switch outcome {
            case .index(let idx): choice = String(idx + 1)
            case .cancelled: return
            }
        } else {
            Output.infoLine("1. 麥克風  2. 引擎  3. 語言  4. 自動轉錄開關(目前:\(config.autoTranscribe ?? true))")
            guard let c = readLine()?.trimmingCharacters(in: .whitespaces) else { return }
            choice = c
        }
        switch choice {
        case "1":
            let devices = AudioDevices.inputDevices()
            switch MicPicker.pick(devices: devices) {
            case .device(let d): config.mic = d.uid
            case .systemDefault: config.mic = nil
            case .noInput: return
            }
        case "2":
            let engineItems = ["apple(macOS 原生)", "whisper(本機高精度)"]
            let e: String
            if let outcome = ArrowMenu.select(title: "選引擎(↑↓ 選擇,Enter/數字確認,q/Esc 取消):", items: engineItems) {
                switch outcome {
                case .index(let idx): e = String(idx + 1)
                case .cancelled: return
                }
            } else {
                Output.infoLine("1. apple(macOS 原生)  2. whisper(本機高精度)")
                guard let raw = readLine()?.trimmingCharacters(in: .whitespaces) else { return }
                e = raw
            }
            config.engine = e == "2" ? "whisper" : "apple"
        case "3":
            Output.infoLine("語言代碼(system/en/zhTW/ja/ko/zhCN):")
            guard let l = readLine()?.trimmingCharacters(in: .whitespaces), parseLanguage(l) != nil else {
                Output.errLine("未辨識的語言代碼,未變更"); return
            }
            config.language = l
        case "4":
            config.autoTranscribe = !(config.autoTranscribe ?? true)
        default: return
        }
        try? CLIConfigStore.save(config)
        Output.infoLine("已儲存設定")
    }

    /// 共用的 hook 執行 glue(選單「最近錄音→執行後製」用)。
    static func runHook(_ hook: HookSpec, stage: String, audio: String, transcript: String?,
                        name: String, dir: String, elapsed: TimeInterval) async -> HookRunner.RunOutcome {
        let command = HookRunner.substitute(hook.command, audio: audio, transcript: transcript, name: name, dir: dir)
        let env = HookRunner.environment(audio: audio, transcript: transcript, name: name, dir: dir)
        let stdinData = HookRunner.stdinMetadataJSON(stage: stage, audio: audio, transcript: transcript, name: name, dir: dir)
        let timeout = hook.timeout.resolvedSeconds(audioDurationSec: elapsed)
        return await HookRunner.execute(command: command, cwd: hook.cwd, env: env, stdinData: stdinData, timeoutSec: timeout)
    }
}

extension Output {
    /// `print` 對應版,支援自訂 terminator(選單提示字 `> ` 不換行)。
    static func infoLine(_ s: String, terminator: String) {
        print(s, terminator: terminator)
        fflush(stdout)
    }
}

/// 互動模式的錄音畫面驅動者(狀態機:錄音中↔已暫停,Enter 結束,m 換麥克風)。
@MainActor
final class InteractiveRecordingSession {
    private let controller: RecordingController
    private var stopRequested = false
    private var savedTermios: termios?
    private var sigintSource: DispatchSourceSignal?

    /// #949:建 controller 時就指定錄音資料夾;租約/state 標 owner=cli。
    init(recordingsDir: URL) {
        controller = RecordingController(recordingsDir: recordingsDir)
        controller.leaseOwner = "cli"
    }

    func run(name: String, config: inout CLIConfigSchema) async {
        await controller.requestPermissions()
        controller.engine = resolveEngine(config.engine)
        if let langRaw = config.language, let lang = parseLanguage(langRaw) { controller.language = lang }
        controller.autoTranscribeAfterStop = false

        if let savedKey = config.mic, let device = findDevice(key: savedKey, in: controller.availableInputDevices) {
            controller.setPreferredInputDevice(device)
        } else if config.mic == nil, Output.isStdinTTY {
            switch MicPicker.pick(devices: controller.availableInputDevices) {
            case .device(let d):
                controller.setPreferredInputDevice(d)
                config.mic = d.uid
                try? CLIConfigStore.save(config)
            default: break
            }
        }

        controller.currentTitle = name
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        try? StateStore.writePID(pid)

        installSignalHandler()
        controller.startRecording()
        let startedAt = Date()
        guard controller.state == .recording else {
            Output.errLine("錄音未能啟動(state=\(controller.state))\(controller.lastError.map { ":\($0)" } ?? "")")
            teardownSignalHandler()
            StateStore.removePIDFile(ifPID: pid)   // #949:state.json 可能是 GUI owner 的,不刪
            return
        }

        Output.infoLine("🦜 錄音中… [p] 暫停/繼續  [Enter] 結束並轉錄  [m] 換麥克風")
        savedTermios = RawMode.enable()

        await recordingLoop(name: name, startedAt: startedAt)

        if let saved = savedTermios { RawMode.restore(saved); savedTermios = nil }
        teardownSignalHandler()
        print("")

        await postProcess(name: name, config: config)
        StateStore.cleanup()
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in Task { @MainActor in self?.stopRequested = true } }
        src.resume()
        sigintSource = src
    }

    private func teardownSignalHandler() {
        sigintSource?.cancel()
        sigintSource = nil
        signal(SIGINT, SIG_DFL)
    }

    private func recordingLoop(name: String, startedAt: Date) async {
        var previousLineCount = 0
        var lastOtherSignalAt = Date()
        var lastYouSignalAt = Date()
        var lastSecondTick = Date.distantPast

        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)

            if let key = RawMode.pollKey() {
                switch key {
                case "p":
                    if controller.state == .recording { controller.pause() }
                    else if controller.state == .paused { controller.resume() }
                case "\n", "\r":
                    stopRequested = true
                case "m":
                    if let saved = savedTermios { RawMode.restore(saved) }
                    print("")
                    switch MicPicker.pick(devices: controller.availableInputDevices) {
                    case .device(let d): controller.switchMic(to: d)
                    default: break
                    }
                    savedTermios = RawMode.enable()
                    previousLineCount = 0
                default: break
                }
            }

            if controller.otherLevel > 0.003 { lastOtherSignalAt = Date() }
            if controller.youLevel > 0.003 { lastYouSignalAt = Date() }

            guard controller.state == .recording || controller.state == .paused else { break }
            if stopRequested { controller.stop(); break }

            let now = Date()
            if now.timeIntervalSince(lastSecondTick) >= 0.5 {   // #949 REC-34:owner 每 0.5 秒寫
                lastSecondTick = now
                writeState(startedAt: startedAt, name: name)
                pollCommands()
            }

            let frame = Meter.Frame(
                otherLevel: controller.otherLevel, youLevel: controller.youLevel,
                otherHasSignal: controller.sysHasSignal, youHasSignal: controller.micHasSignal,
                otherSilentFor: Date().timeIntervalSince(lastOtherSignalAt),
                youSilentFor: Date().timeIntervalSince(lastYouSignalAt),
                elapsed: controller.elapsed,
                name: name + (controller.state == .paused ? "  【已暫停】" : ""),
                warning: controller.deviceChangeWarning, lastError: controller.lastError)
            let (text, count) = Meter.render(frame, useColor: Output.useColor, previousLineCount: previousLineCount)
            print(text)
            previousLineCount = count
        }
    }

    private func writeState(startedAt: Date, name: String) {
        let s = CLIRecordingState(
            pid: Int32(ProcessInfo.processInfo.processIdentifier), startedAt: ISO8601.string(startedAt),
            audioPath: controller.inprogressAudioPath ?? "", name: name, state: controller.state == .paused ? "paused" : "recording",
            levels: .init(other: Double(controller.otherLevel), you: Double(controller.youLevel),
                         otherSignal: controller.sysHasSignal, youSignal: controller.micHasSignal),
            warning: controller.deviceChangeWarning, updatedAt: ISO8601.string(),
            // #949 REC-34 新欄位
            owner: "cli", sessionId: controller.sessionId ?? "", elapsed: controller.liveElapsed,
            paused: controller.state == .paused, markers: controller.markerCount)
        try? StateStore.writeState(s)
    }

    /// #949 REC-36:互動錄音也收 commands/(GUI 橫幅的停止／暫停／繼續);mark 只回 ok(CLI 沒有筆記)。
    private func pollCommands() {
        guard let sid = controller.sessionId else { return }
        let started = controller.heldLease.flatMap { ISO8601.date($0.startedAt) } ?? Date.distantPast
        for cmd in RecordingCommandStore.pending() {
            if let why = RecordingCommand.rejection(cmd, sessionId: sid, sessionStartedAt: started) {
                RecordingCommandStore.complete(cmd.requestId, ok: false, result: why); continue
            }
            switch cmd.cmd {
            case "stop": stopRequested = true; RecordingCommandStore.complete(cmd.requestId, ok: true, result: "stopping")
            case "pause": controller.pause(); RecordingCommandStore.complete(cmd.requestId, ok: controller.state == .paused, result: "\(controller.state)")
            case "resume": controller.resume(); RecordingCommandStore.complete(cmd.requestId, ok: controller.state == .recording, result: "\(controller.state)")
            case "title": if let t = cmd.args["title"] { controller.currentTitle = t }; RecordingCommandStore.complete(cmd.requestId, ok: true, result: controller.currentTitle)
            default: RecordingCommandStore.complete(cmd.requestId, ok: true, result: cmd.cmd)
            }
            if cmd.cmd == "stop" { break }
        }
    }

    // MARK: - 後製(結束錄音後):有 auto=false 的 hook → 現場問(D6 軌 B 規格)

    private func postProcess(name: String, config: CLIConfigSchema) async {
        // #949:用 stop() 真的建的那一筆;發布失敗/太短進隔離區時 lastError 帶原因。
        guard let recID = controller.lastStoppedRecordingID else {
            Output.errLine(controller.lastError ?? "錄音時間過短,未儲存檔案")
            return
        }
        let deadline = Date().addingTimeInterval(max(600, controller.elapsed * 4) + 600)
        while let rec = controller.recordings.first(where: { $0.id == recID }), rec.isConverting {
            if Date() > deadline { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let rec = controller.recordings.first(where: { $0.id == recID }) else {
            Output.errLine(controller.lastError ?? "錄音檔轉檔失敗或被判定為空檔")
            return
        }
        Output.infoLine("已停止錄音:\(rec.url.path)")

        let base = rec.url.deletingPathExtension()
        let txtPath = base.appendingPathExtension("txt").path
        var transcriptPath: String?

        if let hook = config.hooks?["transcribe"], hook.auto, HookTrust.isApproved(config.hooks) {
            let outcome = await InteractiveMenu.runHook(hook, stage: "transcribe", audio: rec.url.path,
                                                        transcript: nil, name: rec.title,
                                                        dir: rec.url.deletingLastPathComponent().path,
                                                        elapsed: controller.elapsed)
            let nonEmpty = (try? FileManager.default.attributesOfItem(atPath: txtPath)[.size] as? UInt64).flatMap { $0 } ?? 0 > 0
            if outcome.exitCode == 0 && !outcome.timedOut && nonEmpty {
                transcriptPath = txtPath
            } else {
                Output.errLine("transcribe hook 未產出有效逐字稿,改用內建轉錄")
                transcriptPath = await builtinTranscribe(rec: rec, txtPath: txtPath)
            }
        } else {
            transcriptPath = await builtinTranscribe(rec: rec, txtPath: txtPath)
        }

        if let transcriptPath { Output.infoLine("逐字稿:\(transcriptPath)") }

        // D6 軌 B:auto=false 的 hook 現場問要不要跑(對應「人工通知 HH session 後製」流程)。
        if let hook = config.hooks?["minutes"], !hook.auto {
            guard HookTrust.isApproved(config.hooks) else {
                Output.infoLine("(有設定 minutes hook 但尚未核准,略過——先跑 myparrot hooks approve)")
                return
            }
            var runMinutes = false
            if let outcome = ArrowMenu.select(title: "後製(↑↓ 選擇,Enter/數字確認,q/Esc=略過):",
                                              items: ["現在交給 AI 後製", "略過"]) {
                if case .index(0) = outcome { runMinutes = true }
            } else {
                Output.infoLine("1. 現在交給 AI 後製  2. 略過")
                runMinutes = readLine()?.trimmingCharacters(in: .whitespaces) == "1"
            }
            if runMinutes {
                let outcome = await InteractiveMenu.runHook(hook, stage: "minutes", audio: rec.url.path,
                                                            transcript: transcriptPath, name: rec.title,
                                                            dir: rec.url.deletingLastPathComponent().path,
                                                            elapsed: controller.elapsed)
                Output.infoLine(outcome.exitCode == 0 && !outcome.timedOut ? "後製完成" : "後製失敗:exit \(outcome.exitCode)")
            }
        } else if let hook = config.hooks?["minutes"], hook.auto, HookTrust.isApproved(config.hooks) {
            let outcome = await InteractiveMenu.runHook(hook, stage: "minutes", audio: rec.url.path,
                                                        transcript: transcriptPath, name: rec.title,
                                                        dir: rec.url.deletingLastPathComponent().path,
                                                        elapsed: controller.elapsed)
            Output.infoLine(outcome.exitCode == 0 && !outcome.timedOut ? "後製完成" : "後製失敗:exit \(outcome.exitCode)")
        }
        Output.infoLine("按任意鍵回主選單…")
        _ = readLine()
    }

    private func builtinTranscribe(rec: Recording, txtPath: String) async -> String? {
        controller.transcribe(rec)
        while controller.isTranscribing { try? await Task.sleep(nanoseconds: 300_000_000) }
        let nonEmpty = (try? FileManager.default.attributesOfItem(atPath: txtPath)[.size] as? UInt64).flatMap { $0 } ?? 0 > 0
        if let err = controller.lastError, !nonEmpty { Output.errLine("轉逐字稿失敗:\(err)"); return nil }
        return nonEmpty ? txtPath : nil
    }
}
