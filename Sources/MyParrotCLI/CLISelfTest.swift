import Foundation
import ArgumentParser
import MyParrotCore
#if canImport(Darwin)
import Darwin
#endif

/// **技術選型/檔案結構偏離紀錄**:plan §1 的檔案清單沒列這支檔案,Package.swift
/// 也被限定「只加 plan §4.1 指定內容」(不能另開 CLITests target 讓
/// `swift test` 認得 CLI 的純函式)。CLI-01/CLI-02 在 Phase 0 表裡標
/// 🟢(自動-SelfTest)——為了不讓這兩案「型別上要求自動化」變成無法兌現,比照
/// 專案既有的 `MyParrotSelfTest` 慣例(純 CLT 執行檔、不需要 Xcode/XCTest),
/// 在 CLI 內部做一個隱藏子命令(`myparrot selftest`,`shouldDisplay: false`,
/// 不進 --help、不算進 D2 拍板的 8 個命令面)重演同一招。詳細取捨記在
/// notes.md。
enum CLISelfTest {

    struct Result: Sendable {
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run() -> [Result] {
        [
            exitCodeValues(),
            parseDurationCases(),
            resolveEngineFlagCases(),
            resolveEngineMapping(),
            parseLanguageCases(),
            expandTildeCase(),
            resolvedRecordingsDirCases(),
            findDeviceCases(),
            hookTimeoutAutoCalc(),
            hookTemplateSubstitution(),
            hookEnvironmentVars(),
            jsonLineEncoding(),
            configKeyPathRoundTrip(),
            hookTrustDigestDeterminism(),
            transcribeHookSuccessJudging(),
            meterBarCellsRule(),
            meterDBString(),
            pidfileStaleDetection(),
            stateFileAtomicRoundTrip(),
            micPickerCases(),
        ]
    }

    // MARK: - Cases(internal,非 private,方便未來若真的接進 XCTest/Swift Testing 重用)

    static func exitCodeValues() -> Result {
        let want: [(MPExitCode, Int32)] = [
            (.success, 0), (.argumentError, 2), (.permissionDenied, 3),
            (.recordingFailed, 4), (.transcriptionFailed, 5), (.hookFailedStrict, 6)
        ]
        let ok = want.allSatisfy { $0.0.rawValue == $0.1 }
        return Result(name: "exit code 對映(§2.4)", passed: ok, detail: ok ? "" : "\(want)")
    }

    static func parseDurationCases() -> Result {
        let cases: [(String, TimeInterval?)] = [
            ("30s", 30), ("10m", 600), ("4h", 14400), ("90", 90),
            ("1.5h", 5400), ("", nil), ("abc", nil), ("-5s", nil), ("0s", nil)
        ]
        var failures: [String] = []
        for (input, want) in cases {
            let got = parseDuration(input)
            if got != want { failures.append("\(input) → \(String(describing: got)),want \(String(describing: want))") }
        }
        return Result(name: "--max-duration 解析(30s/10m/4h/純數字)", passed: failures.isEmpty, detail: failures.joined(separator: "; "))
    }

    static func resolveEngineFlagCases() -> Result {
        let ok = resolveEngineFlag("apple") == "apple" && resolveEngineFlag("whisper") == "whisper"
                 && resolveEngineFlag("cloud") == nil && resolveEngineFlag("") == nil
        return Result(name: "--engine 旗標驗證(apple|whisper)", passed: ok, detail: ok ? "" : "見程式碼")
    }

    static func resolveEngineMapping() -> Result {
        let ok = resolveEngine("apple") == .appleNative && resolveEngine("whisper") == .whisperKit
                 && resolveEngine(nil) == .appleNative && resolveEngine("bogus") == .appleNative
        return Result(name: "config engine 字串 → TranscriptionEngine", passed: ok, detail: ok ? "" : "見程式碼")
    }

    static func parseLanguageCases() -> Result {
        let ok = parseLanguage("zhTW") == .zhTW && parseLanguage("zh-TW") == .zhTW
                 && parseLanguage("system") == .system && parseLanguage("en-US") == .en
                 && parseLanguage("not-a-lang") == nil
        return Result(name: "language 字串解析(rawValue+連字號別名)", passed: ok, detail: ok ? "" : "見程式碼")
    }

    static func expandTildeCase() -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = expandTilde("~/Documents/MyParrot")
        let ok = expanded == home + "/Documents/MyParrot"
        return Result(name: "~ 展開", passed: ok, detail: ok ? "" : expanded)
    }

    static func resolvedRecordingsDirCases() -> Result {
        let defaultDir = resolvedRecordingsDir(CLIConfigSchema())
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyParrot", isDirectory: true)
        let customDir = resolvedRecordingsDir(CLIConfigSchema(recordingsDir: "~/tmp-myparrot-test"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ok = defaultDir.path == docs.path && customDir.path == home + "/tmp-myparrot-test"
        return Result(name: "resolvedRecordingsDir(預設同 GUI/自訂展開 ~)", passed: ok,
                      detail: ok ? "" : "default=\(defaultDir.path) custom=\(customDir.path)")
    }

    static func findDeviceCases() -> Result {
        let devices = [
            AudioInputDevice(id: 1, name: "MacBook Pro 麥克風", uid: "builtin-uid", isBuiltIn: true),
            AudioInputDevice(id: 2, name: "AirPods Pro", uid: "airpods-uid", isBluetooth: true)
        ]
        let byUID = findDevice(key: "airpods-uid", in: devices)
        let byName = findDevice(key: "airpods", in: devices)
        let byID = findDevice(key: "1", in: devices)
        let miss = findDevice(key: "nope", in: devices)
        let ok = byUID?.uid == "airpods-uid" && byName?.uid == "airpods-uid" && byID?.id == 1 && miss == nil
        return Result(name: "findDevice(uid 優先/名稱包含/id 數字)", passed: ok, detail: ok ? "" : "見程式碼")
    }

    static func hookTimeoutAutoCalc() -> Result {
        let short = HookTimeout.auto.resolvedSeconds(audioDurationSec: 60)       // 60*4=240 < 600 → 600
        let long = HookTimeout.auto.resolvedSeconds(audioDurationSec: 5400)      // 5400*4=21600 > 600
        let unlimited = HookTimeout.seconds(0).resolvedSeconds(audioDurationSec: 100)
        let fixed = HookTimeout.seconds(45).resolvedSeconds(audioDurationSec: 100)
        let ok = short == 600 && long == 21600 && unlimited == nil && fixed == 45
        return Result(name: "hook timeout auto=max(600,音長×4)/0=不限時", passed: ok,
                      detail: ok ? "" : "short=\(String(describing: short)) long=\(String(describing: long)) unlimited=\(String(describing: unlimited)) fixed=\(String(describing: fixed))")
    }

    static func hookTemplateSubstitution() -> Result {
        let out = HookRunner.substitute("whisper-cli {audio} -o {dir} # {name} {transcript}",
                                        audio: "/a/b.m4a", transcript: "/a/b.txt", name: "週會", dir: "/a")
        // v0.3.1:值一律 shell 單引號包裹(檔名 `a; rm -rf ~` 不能變 shell 語法)。
        let want = "whisper-cli '/a/b.m4a' -o '/a' # '週會' '/a/b.txt'"
        let outNilTranscript = HookRunner.substitute("{transcript}", audio: "x", transcript: nil, name: "n", dir: "d")
        let injected = HookRunner.substitute("tool {audio}", audio: "/x/a; touch pwned; echo 'q'.m4a",
                                             transcript: nil, name: "n", dir: "d")
        let injectedOK = injected == "tool '/x/a; touch pwned; echo '\\''q'\\''.m4a'"
        let ok = out == want && outNilTranscript == "''" && injectedOK
        return Result(name: "hook 模板替換 {audio}/{transcript}/{name}/{dir}", passed: ok, detail: ok ? "" : out)
    }

    static func hookEnvironmentVars() -> Result {
        let env = HookRunner.environment(audio: "/a.m4a", transcript: "/a.txt", name: "n", dir: "/a")
        let ok = env["MYPARROT_AUDIO"] == "/a.m4a" && env["MYPARROT_TRANSCRIPT"] == "/a.txt"
                 && env["MYPARROT_NAME"] == "n" && env["MYPARROT_DIR"] == "/a"
                 && env["MYPARROT_CHANNEL_LEFT"] == "對方" && env["MYPARROT_CHANNEL_RIGHT"] == "你"
        return Result(name: "hook env 變數(MYPARROT_*+分軌語意)", passed: ok, detail: ok ? "" : "\(env)")
    }

    static func jsonLineEncoding() -> Result {
        let line = JSONLine.encode(["event": "started", "pid": 123, "ok": true, "skip": nil as String?, "dur": 12.5])
        let hasAllKeys = line.contains("\"event\":\"started\"") && line.contains("\"pid\":123")
            && line.contains("\"ok\":true") && line.contains("\"dur\":12.5") && !line.contains("skip")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let roundTrips = parsed?["event"] as? String == "started" && parsed?["pid"] as? Int == 123
        let escaped = JSONLine.escapeString("a\"b\\c\n")
        let escapeOK = escaped == "\"a\\\"b\\\\c\\n\""
        let ok = hasAllKeys && roundTrips && escapeOK
        return Result(name: "JSONLine 編碼(nil 略過欄位/可被 JSONSerialization 讀回/跳脫)", passed: ok,
                      detail: ok ? "" : "line=\(line) escaped=\(escaped)")
    }

    static func configKeyPathRoundTrip() -> Result {
        var config = CLIConfigSchema()
        do {
            try ConfigKeyPath.set(&config, path: "mic", value: "some-uid")
            try ConfigKeyPath.set(&config, path: "autoTranscribe", value: "false")
            try ConfigKeyPath.set(&config, path: "hooks.transcribe.command", value: "whisper-cli {audio}")
            try ConfigKeyPath.set(&config, path: "hooks.transcribe.auto", value: "true")
            try ConfigKeyPath.set(&config, path: "hooks.transcribe.timeout", value: "auto")
        } catch {
            return Result(name: "ConfigKeyPath set/get round-trip", passed: false, detail: "\(error)")
        }
        let micOK = ConfigKeyPath.get(config, path: "mic") == "\"some-uid\""
        let autoOK = ConfigKeyPath.get(config, path: "autoTranscribe") == "false"
        let cmdOK = ConfigKeyPath.get(config, path: "hooks.transcribe.command") == "\"whisper-cli {audio}\""
        let hookAutoOK = ConfigKeyPath.get(config, path: "hooks.transcribe.auto") == "true"
        var invalidThrew = false
        do { try ConfigKeyPath.set(&config, path: "bogus.path", value: "x") } catch { invalidThrew = true }
        let ok = micOK && autoOK && cmdOK && hookAutoOK && invalidThrew
        return Result(name: "ConfigKeyPath set/get round-trip(含未知路徑報錯)", passed: ok,
                      detail: ok ? "" : "mic=\(micOK) auto=\(autoOK) cmd=\(cmdOK) hookAuto=\(hookAutoOK) invalidThrew=\(invalidThrew)")
    }

    static func hookTrustDigestDeterminism() -> Result {
        let hooksA: [String: HookSpec] = ["transcribe": HookSpec(command: "echo a", auto: true)]
        let hooksB: [String: HookSpec] = ["transcribe": HookSpec(command: "echo a", auto: true)]
        let hooksC: [String: HookSpec] = ["transcribe": HookSpec(command: "echo b", auto: true)]
        let dA = HookTrust.normalizedDigestHex(hooksA)
        let dB = HookTrust.normalizedDigestHex(hooksB)
        let dC = HookTrust.normalizedDigestHex(hooksC)
        let dNil = HookTrust.normalizedDigestHex(nil)
        let ok = dA == dB && dA != dC && dA.count == 64 && dNil.count == 64
        return Result(name: "hooks trust SHA256 digest 決定性(同內容同雜湊/不同內容不同雜湊)", passed: ok,
                      detail: ok ? "" : "dA=\(dA) dB=\(dB) dC=\(dC)")
    }

    static func transcribeHookSuccessJudging() -> Result {
        let existing: Set<String> = ["/rec/a.txt", "/rec/b.txt"]
        func exists(_ p: String) -> Bool { existing.contains(p) }

        let ok1 = HookRunner.transcribeHookSucceeded(exitCode: 0, stdout: "", expectedTxtPath: "/rec/a.txt", fileExistsNonEmpty: exists)
        let ok2 = HookRunner.transcribeHookSucceeded(exitCode: 0, stdout: "some log\n{\"transcript\":\"/rec/b.txt\"}",
                                                     expectedTxtPath: "/rec/nope.txt", fileExistsNonEmpty: exists)
        let fail1 = HookRunner.transcribeHookSucceeded(exitCode: 1, stdout: "", expectedTxtPath: "/rec/a.txt", fileExistsNonEmpty: exists)
        let fail2 = HookRunner.transcribeHookSucceeded(exitCode: 0, stdout: "", expectedTxtPath: "/rec/nope.txt", fileExistsNonEmpty: exists)
        let ok = ok1.ok && ok2.ok && ok2.transcriptPath == "/rec/b.txt" && !fail1.ok && !fail2.ok
        return Result(name: "hook 產物驗證(exit0+檔案存在 或 exit0+stdout末行JSON;防靜默失敗)", passed: ok,
                      detail: ok ? "" : "ok1=\(ok1) ok2=\(ok2) fail1=\(fail1) fail2=\(fail2)")
    }

    static func meterBarCellsRule() -> Result {
        let zero = Meter.barCells(level: 0, width: 40)
        let tiny = Meter.barCells(level: 0.006, width: 40)     // >0.005 → 至少 1 格(UI-22 教訓)
        let belowFloor = Meter.barCells(level: 0.001, width: 40)  // 太小,不硬性給 1 格
        let full = Meter.barCells(level: 1.0, width: 40)
        let half = Meter.barCells(level: 0.5, width: 40)
        let ok = zero == 0 && tiny >= 1 && belowFloor == 0 && full == 40 && half == 20
        return Result(name: "Meter 格數規則(level>0.005 至少 1 格,UI-22 教訓)", passed: ok,
                      detail: ok ? "" : "zero=\(zero) tiny=\(tiny) belowFloor=\(belowFloor) full=\(full) half=\(half)")
    }

    static func meterDBString() -> Result {
        let silent = Meter.dBString(0)
        let full = Meter.dBString(1.0)
        let ok = silent == "-∞dB" && full == "0dB"
        return Result(name: "Meter dB 字串(靜音=-∞dB,滿格=0dB)", passed: ok, detail: ok ? "" : "silent=\(silent) full=\(full)")
    }

    static func pidfileStaleDetection() -> Result {
        withIsolatedConfigDir { _ in
            let alive = Int32(ProcessInfo.processInfo.processIdentifier)
            let staleCandidate: Int32 = 999_999   // 系統 pid 上限內幾乎不可能存在的 pid
            let aliveIsStale = StateStore.isStalePID(alive)
            let staleIsStale = StateStore.isStalePID(staleCandidate)
            let ok = !aliveIsStale && staleIsStale
            return Result(name: "pidfile stale 偵測(kill(pid,0) ESRCH → stale;自己的 pid → 活的)", passed: ok,
                          detail: ok ? "" : "aliveIsStale=\(aliveIsStale) staleIsStale=\(staleIsStale)")
        }
    }

    static func stateFileAtomicRoundTrip() -> Result {
        withIsolatedConfigDir { _ in
            let state = CLIRecordingState(
                pid: 42, startedAt: "2026-08-10T00:00:00Z", audioPath: "/a.m4a", name: "測試",
                state: "recording", levels: .init(other: 0.1, you: 0.2, otherSignal: true, youSignal: false),
                warning: nil, updatedAt: "2026-08-10T00:00:01Z")
            do {
                try StateStore.writePID(42)
                try StateStore.writeState(state)
            } catch {
                return Result(name: "state.json/pidfile 原子寫入+讀回", passed: false, detail: "\(error)")
            }
            let readBack = StateStore.readState()
            let pidBack = StateStore.readPID()
            StateStore.cleanup()
            let cleanedUp = StateStore.readState() == nil && StateStore.readPID() == nil
            let ok = readBack == state && pidBack == 42 && cleanedUp
            return Result(name: "state.json/pidfile 原子寫入+讀回+cleanup", passed: ok,
                          detail: ok ? "" : "readBack=\(String(describing: readBack)) pidBack=\(String(describing: pidBack)) cleanedUp=\(cleanedUp)")
        }
    }

    static func micPickerCases() -> Result {
        let devices = [
            AudioInputDevice(id: 1, name: "內建麥克風", uid: "builtin-uid", isBuiltIn: true),
            AudioInputDevice(id: 2, name: "AirPods", uid: "airpods-uid", isBluetooth: true),
            AudioInputDevice(id: 3, name: "iPhone", uid: "iphone-uid", isContinuityWireless: true)
        ]
        var calls = 0
        func nth(_ answers: [String?]) -> () -> String? {
            calls = 0
            return { defer { calls += 1 }; return calls < answers.count ? answers[calls] : nil }
        }
        // useArrowKeys: false——這裡要測的是 readLine() fallback 路徑本身
        // (注入假答案驗證編號/空白/EOF/無效輸入語意),不該在測試環境真的去
        // grab 終端 raw mode(測試環境是否為真 TTY 不保證,也不該受影響)。
        let pickSecond = MicPicker.pick(devices: devices, readLineFn: nth(["2"]), useArrowKeys: false)
        let pickEmpty = MicPicker.pick(devices: devices, readLineFn: nth([""]), useArrowKeys: false)
        let pickEOF = MicPicker.pick(devices: devices, readLineFn: nth([]), useArrowKeys: false)
        let pickBad = MicPicker.pick(devices: devices, readLineFn: nth(["999"]), useArrowKeys: false)
        let pickNoDevices = MicPicker.pick(devices: [], readLineFn: nth(["1"]), useArrowKeys: false)

        var secondOK = false
        if case .device(let d) = pickSecond, d.uid == "airpods-uid" { secondOK = true }
        var emptyOK = false
        if case .systemDefault = pickEmpty { emptyOK = true }
        var eofOK = false
        if case .noInput = pickEOF { eofOK = true }
        var badOK = false
        if case .systemDefault = pickBad { badOK = true }
        var noDevOK = false
        if case .systemDefault = pickNoDevices { noDevOK = true }

        let btLabel = MicPicker.label(for: devices[1])
        let phoneLabel = MicPicker.label(for: devices[2])
        let labelOK = btLabel == "⚠️ AirPods(藍牙)" && phoneLabel == "iPhone(iPhone)"

        let ok = secondOK && emptyOK && eofOK && badOK && noDevOK && labelOK
        return Result(name: "MicPicker.pick(編號選擇/空白=系統預設/EOF/無效輸入/無裝置)+標記文字",
                      passed: ok,
                      detail: ok ? "" : "second=\(secondOK) empty=\(emptyOK) eof=\(eofOK) bad=\(badOK) noDev=\(noDevOK) labelOK=\(labelOK)(bt=\(btLabel) phone=\(phoneLabel))")
    }

    /// 借一個暫存目錄當 `MYPARROT_CONFIG_DIR`,測完還原(GUI-verify-discipline:
    /// 改機上狀態要能還原)。用 `setenv`/`unsetenv` 而非碰真正的
    /// `~/.config/myparrot`,不留殘。
    private static func withIsolatedConfigDir(_ body: (URL) -> Result) -> Result {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("myparrot-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = getenv("MYPARROT_CONFIG_DIR").map { String(cString: $0) }
        setenv("MYPARROT_CONFIG_DIR", tmp.path, 1)
        defer {
            if let previous { setenv("MYPARROT_CONFIG_DIR", previous, 1) } else { unsetenv("MYPARROT_CONFIG_DIR") }
            try? FileManager.default.removeItem(at: tmp)
        }
        return body(tmp)
    }
}

/// 隱藏子命令:`myparrot selftest`。不列進 `--help`(shouldDisplay: false),
/// 不算進 D2 拍板的 8 個命令面——純粹是「CLI-01/02 純函式回歸怎麼自動化」這個
/// Package.swift 限制下的技術解法,詳見型別上方註解。
struct CLISelfTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", shouldDisplay: false)

    func run() throws {
        let results = CLISelfTest.run()
        print("🦜 MyParrot CLI 自我測試")
        print(String(repeating: "=", count: 40))
        var failed = 0
        for r in results {
            let mark = r.passed ? "✅ PASS" : "❌ FAIL"
            let detail = r.detail.isEmpty ? "" : "  — \(r.detail)"
            print("\(mark)  \(r.name)\(detail)")
            if !r.passed { failed += 1 }
        }
        print(String(repeating: "=", count: 40))
        print("\(results.count - failed)/\(results.count) 通過")
        if failed > 0 { MPExitCode.argumentError.terminate() }
    }
}
