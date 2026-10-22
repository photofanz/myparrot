import Foundation

/// #2438 Phase 2(MIN-01):校正層與會議記錄**共用**的 `claude` CLI 子行程 runner。兩個 provider 只各自決定
/// 提示詞與 schema,呼叫配方在這裡鎖死一份(CORR-13 的 SelfTest 當回歸閘):
/// 非互動 `-p`、JSON schema 鎖輸出、不載任何設定、只留 StructuredOutput 一個工具、單回合、不留 session、
/// 空暫存夾當工作目錄、stdin 接 /dev/null、逾時 kill 整個行程組。
///
/// 實測(claude 2.1.295,#2417):每次脈絡 1.2～1.9k tokens。🚫 不帶 `--bare`(只認 API key,等於強迫付費)、
/// 🚫 不帶 `--tools ""`(脈絡反而 140k)、🚫 不拿 `--disallowedTools` 當替代(工具定義照樣送)。
/// 🔴 `--strict-mcp-config` 必帶(2026-10-17 03:3x 實測):GUI 給子行程的 PATH 只要讓 MCP 伺服器的執行檔找得到
/// (/usr/local/bin、/opt/homebrew/bin),CLI 就把它們啟動、整套工具定義灌進脈絡(49k～147k);加這個旗標一律 1.2k。
public enum ClaudeCLIRunner {

    // MARK: - 找 CLI(CORR-05)

    /// 候選路徑:PATH 各目錄 → ~/.local/bin → Homebrew → /usr/local/bin → ~/.claude/local。GUI app 的 PATH
    /// 通常不含使用者的 shell 設定,所以後面幾個要自己補。
    public static func locate(environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        var dirs: [String] = (environmentPath ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
        for d in dirs where !d.isEmpty {
            let p = "\(d)/claude"
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// `claude auth status` 回 JSON `{"loggedIn": true, …}`;拿不到就當未登入。
    public static func isLoggedIn(executable: URL) async -> Bool {
        let out = await run(executable: executable, arguments: ["auth", "status"], cwd: nil, timeout: 15)
        guard out.exitCode == 0, let data = out.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["loggedIn"] as? Bool ?? false
    }

    // MARK: - 參數(純函式,CORR-13／MIN-01 的靜態斷言對象)

    public static func arguments(userPrompt: String, systemPrompt: String, schema: String, model: String?) -> [String] {
        var args = ["-p", userPrompt,
                    "--output-format", "json",
                    "--json-schema", schema,
                    "--setting-sources", "",
                    "--system-prompt", systemPrompt,
                    "--tools", "StructuredOutput",
                    "--max-turns", "1",
                    "--no-session-persistence",
                    "--strict-mcp-config"]      // 不帶 --mcp-config ⇒ 零 MCP 伺服器
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    /// 這幾個旗標一出現就是配方被改壞。
    /// (`--tools ""` 另外用「值不得為空」判,不在這裡——字串比對會誤殺 `--tools StructuredOutput`。)
    public static let forbiddenFlags: Set<String> = ["--bare", "--dangerously-skip-permissions", "--continue", "--resume"]

    // MARK: - 輸出解析共用

    /// 只認 stdout 最後一行合法 JSON 物件。
    public static func lastJSONObject(in stdout: String) -> [String: Any]? {
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let d = String(line).data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        }
        return nil
    }

    public static func looksNotLoggedIn(stdout: String, stderr: String) -> Bool {
        let combined = stdout + "\n" + stderr
        return combined.contains("Not logged in") || combined.contains("Please run /login")
    }

    /// `usage`:輸入＝input＋cache_creation＋cache_read(都算脈絡);輸出與耗時原樣。
    public static func usage(_ obj: [String: Any]) -> (input: Int, output: Int, durationMs: Int) {
        let usage = obj["usage"] as? [String: Any] ?? [:]
        let input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        return (input, usage["output_tokens"] as? Int ?? 0, obj["duration_ms"] as? Int ?? 0)
    }

    // MARK: - 子行程

    public struct RunOutcome: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var launchError: String?
    }

    /// 在新建的空暫存夾裡跑(CLI 在那裡找不到任何 CLAUDE.md／專案設定),結束即刪。`prefix` 讓測試認得出是誰開的。
    public static func runInTemporaryDirectory(executable: URL, arguments: [String], prefix: String, timeout: TimeInterval) async -> RunOutcome {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        return await run(executable: executable, arguments: arguments, cwd: work, timeout: timeout)
    }

    public static func run(executable: URL, arguments: [String], cwd: URL?, timeout: TimeInterval) async -> RunOutcome {
        await Task.detached(priority: .userInitiated) {
            runBlocking(executable: executable, arguments: arguments, cwd: cwd, timeout: timeout)
        }.value
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
    private final class FlagBox: @unchecked Sendable { var flag = false }

    /// 寫法比照 MyParrotCLI 的 HookRunner:stdout/stderr 各開一條執行緒讀到底(防 pipe 塞滿死鎖),
    /// 看門狗逾時先 SIGTERM 再 SIGKILL。
    private static func runBlocking(executable: URL, arguments: [String], cwd: URL?, timeout: TimeInterval) -> RunOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        // GUI 的 PATH 只有系統目錄;補上 CLI 自己的目錄與常見安裝目錄(CLI 會再找自己與 node),
        // 其餘環境照常繼承(OAuth 登入態靠 HOME/鑰匙圈)。
        var env = ProcessInfo.processInfo.environment
        let extra = [executable.deletingLastPathComponent().path,
                     "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin",
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + current).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return RunOutcome(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: "\(error)")
        }
        let outBox = DataBox(), errBox = DataBox(), timedOut = FlagBox()
        let outThread = Thread { outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errThread = Thread { errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile() }
        outThread.start(); errThread.start()
        let pid = process.processIdentifier
        // 新行程組:逾時 killpg 整組(claude 會起子行程,只殺父的話 pipe 被子行程拖住、讀不到 EOF)。
        setpgid(pid, pid)
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: timeout)
            guard kill(pid, 0) == 0 else { return }
            timedOut.flag = true
            killpg(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 3)
            if kill(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
        watchdog.start()
        process.waitUntilExit()
        while !outThread.isFinished || !errThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        return RunOutcome(exitCode: process.terminationStatus,
                          stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                          stderr: String(data: errBox.data, encoding: .utf8) ?? "",
                          timedOut: timedOut.flag, launchError: nil)
    }
}
