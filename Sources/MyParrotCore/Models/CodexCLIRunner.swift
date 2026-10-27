import Foundation

/// #2418 CDX-02／04:本機 `codex` CLI 子行程 runner,校正層與會議記錄**共用**。兩個 provider 只各自決定提示詞與 schema,
/// 呼叫配方在這裡鎖死一份(CDX-04 的 SelfTest 與假 CLI 腳本當回歸閘):
/// `exec` 非互動、`--skip-git-repo-check`(暫存夾不是 repo)、`--ephemeral`(不留 session)、`--ignore-user-config`＋`--ignore-rules`
/// (不載使用者 `~/.codex/config.toml` 的 model／approval／mcp_servers／hooks 與 .rules)、`--sandbox read-only`、`--color never`、
/// `--json`(stdout 吐 JSONL 事件)、`--output-schema <檔>` 鎖最終回覆形狀、`-o <檔>` 把最終訊息落檔;空暫存夾當工作目錄
/// (schema 與輸出檔都放裡面,結束即刪)、stdin 接 /dev/null、子行程由 `ClaudeCLIRunner.run` 跑(同一套讀到底雙執行緒＋killpg 逾時)。
///
/// 實測(codex-cli 0.148.0,2026-10-23 21:24,TEST_PLAN T 節):2 段校正 10.3 s、`turn.completed.usage` input 13,547／output 59、
/// 零指令事件、暫存夾零新檔;拿掉 `--ignore-user-config` 只差 347 tokens ⇒ 帶它是隔離使用者設定,不是省脈絡。
/// 基底約 13.5k tokens／次是 Codex 自己的系統提示＋內建工具,查不到關掉的旗標(對照 Claude CLI 1.2k)。
/// Codex 沒有 `--system-prompt`:系統提示與使用者訊息串成一段(`composePrompt`),**字串本體與 Claude 後端同一份**(CDX-05)。
public enum CodexCLIRunner {

    // MARK: - 找 CLI(CDX-03)

    /// 候選路徑:PATH 各目錄 → ~/.local/bin → Homebrew → /usr/local/bin。實機 `~/.local/bin/codex` 是 symlink
    /// (→ `~/.codex/packages/standalone/current/bin/codex`),`isExecutableFile` 跟著 symlink 走。
    public static func locate(environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        var dirs: [String] = (environmentPath ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs where !d.isEmpty {
            let p = "\(d)/codex"
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// `codex login status`:已登入印 `Logged in using ChatGPT`、exit 0(2026-10-23 實測);其餘一律當未登入
    /// (未登入時的輸出沒驗過——不登出 Eric 的 CLI——所以不猜它長什麼樣)。
    public static func isLoggedIn(executable: URL) async -> Bool {
        let out = await ClaudeCLIRunner.run(executable: executable, arguments: ["login", "status"], cwd: nil, timeout: 15)
        return looksLoggedIn(exitCode: out.exitCode, stdout: out.stdout, stderr: out.stderr)
    }

    public static func looksLoggedIn(exitCode: Int32, stdout: String, stderr: String) -> Bool {
        exitCode == 0 && (stdout + stderr).contains("Logged in")
    }

    // MARK: - 參數(純函式,CDX-04 的靜態斷言對象)

    public static let schemaFileName = "schema.json"
    public static let outputFileName = "last.json"

    /// Codex 沒有獨立的系統提示旗標:兩段串起來,中間空一行。
    public static func composePrompt(systemPrompt: String, userPrompt: String) -> String {
        systemPrompt + "\n\n" + userPrompt
    }

    public static func arguments(prompt: String, schemaPath: String, outputPath: String, model: String?) -> [String] {
        var args = ["exec",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "--ignore-user-config",
                    "--ignore-rules",
                    "--sandbox", "read-only",
                    "--color", "never",
                    "--json",
                    "--output-schema", schemaPath,
                    "-o", outputPath]
        if let model, !model.isEmpty { args += ["-m", model] }
        args.append(prompt)      // 提示詞一定最後(前面全是旗標,不會被當成子命令)
        return args
    }

    /// 這幾個字一出現在參數裡就是配方被改壞(放寬沙箱、可寫目錄、接續舊 session)。
    public static let forbiddenFlags: Set<String> = ["--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
                                                     "--full-auto", "--add-dir", "danger-full-access", "workspace-write",
                                                     "resume", "fork"]

    // MARK: - 子行程

    public struct Outcome: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var launchError: String?
        /// `-o` 檔的內容(最終訊息);沒寫出來＝nil。
        public var lastMessage: String?
        public var durationMs: Int
    }

    /// 新建空暫存夾 → 寫 schema → 跑 → 讀 `-o` 檔 → 刪夾。`prefix` 讓測試認得出是誰開的。
    public static func runInTemporaryDirectory(executable: URL, systemPrompt: String, userPrompt: String, schema: String,
                                               model: String?, prefix: String, timeout: TimeInterval) async -> Outcome {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let schemaURL = work.appendingPathComponent(schemaFileName)
        let outURL = work.appendingPathComponent(outputFileName)
        do { try schema.write(to: schemaURL, atomically: true, encoding: .utf8) } catch {
            return Outcome(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: "無法寫入 schema 暫存檔", lastMessage: nil, durationMs: 0)
        }
        let args = arguments(prompt: composePrompt(systemPrompt: systemPrompt, userPrompt: userPrompt),
                             schemaPath: schemaURL.path, outputPath: outURL.path, model: model)
        let t0 = Date()
        let r = await ClaudeCLIRunner.run(executable: executable, arguments: args, cwd: work, timeout: timeout)
        let last = try? String(contentsOf: outURL, encoding: .utf8)
        return Outcome(exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr, timedOut: r.timedOut, launchError: r.launchError,
                       lastMessage: last, durationMs: Int(Date().timeIntervalSince(t0) * 1000))
    }

    // MARK: - 輸出解析(純函式,CDX-07)

    /// stdout 的 JSONL 事件逐行解析;不是 JSON 物件的行略過。
    public static func events(in stdout: String) -> [[String: Any]] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { jsonObject(String($0)) }
    }

    /// 最終 JSON 物件:`-o` 檔優先;沒有或不是 JSON 就退回 JSONL 最後一則 `agent_message` 的 text。
    public static func finalJSONObject(lastMessage: String?, stdout: String) -> [String: Any]? {
        if let lastMessage, let o = jsonObject(lastMessage) { return o }
        for e in events(in: stdout).reversed() {
            guard e["type"] as? String == "item.completed", let item = e["item"] as? [String: Any],
                  item["type"] as? String == "agent_message", let text = item["text"] as? String else { continue }
            if let o = jsonObject(text) { return o }
        }
        return nil
    }

    private static func jsonObject(_ s: String) -> [String: Any]? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let d = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// `turn.completed.usage`:input＋cached 都算脈絡;output＋reasoning 算輸出。沒有事件 ⇒ 0/0。
    public static func usage(in stdout: String) -> (input: Int, output: Int) {
        for e in events(in: stdout).reversed() where e["type"] as? String == "turn.completed" {
            let u = e["usage"] as? [String: Any] ?? [:]
            return ((u["input_tokens"] as? Int ?? 0) + (u["cached_input_tokens"] as? Int ?? 0),
                    (u["output_tokens"] as? Int ?? 0) + (u["reasoning_output_tokens"] as? Int ?? 0))
        }
        return (0, 0)
    }

    /// 只在非 0 退出時判未登入(exit 0 的輸出是模型回覆,逐字稿裡提到 login 不算)。未登入的實際字樣未驗,兩個常見寫法都認。
    public static func looksNotLoggedIn(exitCode: Int32, stdout: String, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        let c = (stdout + "\n" + stderr).lowercased()
        return c.contains("not logged in") || c.contains("codex login")
    }

    /// CDX-04 真跑斷言用:`agent_message`／`reasoning` 以外的 item(指令執行、改檔、MCP 工具)有幾則。唯讀沙箱下無害,但要記 log。
    public static func toolActivityCount(in stdout: String) -> Int {
        events(in: stdout).filter { e in
            guard e["type"] as? String == "item.completed", let item = e["item"] as? [String: Any],
                  let t = item["type"] as? String else { return false }
            return t != "agent_message" && t != "reasoning"
        }.count
    }
}
