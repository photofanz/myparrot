import Foundation
import ArgumentParser

/// `myparrot config [get|set|path]`(§2.1,§7,Phase 5)。設定檔 schema/store 本身
/// (`CLIConfigSchema`/`CLIConfigStore`/`ConfigKeyPath`)是 §2 共用基礎規格,
/// Phase 1 就已經在用;這支檔案只放命令列介面。
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "設定檔管理",
        subcommands: [ConfigGetCommand.self, ConfigSetCommand.self, ConfigPathCommand.self],
        defaultSubcommand: ConfigGetCommand.self
    )
}

struct ConfigPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "印設定檔路徑")
    func run() throws { print(CLIConfigStore.configPath.path) }
}

struct ConfigGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "印生效設定值(JSON);省略路徑=印整份")
    @Argument(help: "設定路徑,如 mic / hooks.transcribe.command") var path: String?

    func run() throws {
        let config = CLIConfigStore.load()
        if let path {
            guard let value = ConfigKeyPath.get(config, path: path) else {
                Output.errLine("未知設定路徑:\(path)")
                MPExitCode.argumentError.terminate()
            }
            print(value)
        } else {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: (try? enc.encode(config)) ?? Data(), encoding: .utf8) ?? "{}")
        }
    }
}

struct ConfigSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "寫入設定值")
    @Argument(help: "設定路徑") var path: String
    @Argument(help: "值") var value: String

    func run() throws {
        var config = CLIConfigStore.load()
        do {
            try ConfigKeyPath.set(&config, path: path, value: value)
            try CLIConfigStore.save(config)
            Output.infoLine("已設定 \(path) = \(value)")
        } catch {
            Output.errLine("\(error)")
            MPExitCode.argumentError.terminate()
        }
    }
}
