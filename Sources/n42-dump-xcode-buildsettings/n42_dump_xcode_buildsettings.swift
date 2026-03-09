import Foundation

@main
struct n42_dump_xcode_buildsettings {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        do {
            let options = try BuildSettingsTool.parseOptions(arguments: arguments)
            try BuildSettingsTool.run(options: options)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print("Usage: n42-dump-xcode-buildsettings [--all-targets-output <path>]")
        print("Runs xcodebuild settings dump, sanitizes volatile values, and writes per-target JSON files.")
        print("Default all-targets output path: PersistedLogs/buildConfigs/allTargets.json")
    }
}

enum BuildSettingsTool {
    struct Options {
        let allTargetsOutputURL: URL

        static let defaults = Options(
            allTargetsOutputURL: URL(fileURLWithPath: "PersistedLogs/buildConfigs/allTargets.json")
        )
    }

    static let xcodebuildCommand: [String] = ["xcodebuild", "-alltargets", "-showBuildSettings", "-json"]

    static let regexReplacements: [(pattern: String, replacement: String)] = [
        (#"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}"#, "XXXX.XX.XX.XX.XX"),
        (#""N42_GIT_COMMIT_HASH"\s*:\s*"[A-F0-9]{8}""#, #""N42_GIT_COMMIT_HASH" : "XXXXXXXX""#),
        (#"/var/folders/[a-z0-9]*/[a-z0-9_]*/"#, "/var/folders/XX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/")
    ]

    static let quotedValueReplacements: [(key: String, replacement: String)] = [
        ("MAC_OS_X_PRODUCT_BUILD_VERSION", "XXXXXXXX"),
        ("MAC_OS_X_VERSION_ACTUAL", "XXXX"),
        ("MAC_OS_X_VERSION_MAJOR", "XX"),
        ("MAC_OS_X_VERSION_MINOR", "XX"),
        ("PATH", "REDACTED_PATH")
    ]

    static func parseOptions(arguments: [String]) throws -> Options {
        var index = 0
        var allTargetsOutputURL = Options.defaults.allTargetsOutputURL

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--all-targets-output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --all-targets-output.")
                }
                allTargetsOutputURL = URL(fileURLWithPath: arguments[index])
            default:
                throw CLIError.invalidArguments("Unknown argument: \(argument)")
            }
            index += 1
        }

        return Options(allTargetsOutputURL: allTargetsOutputURL)
    }

    static func run(options: Options = .defaults, fileManager: FileManager = .default) throws {
        let combinedOutputURL = options.allTargetsOutputURL
        let outputDirectory = combinedOutputURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: combinedOutputURL) }

        let rawBuildSettings = try runCommand(executable: "/usr/bin/xcrun", arguments: xcodebuildCommand)
        let sanitizedBuildSettings = sanitize(rawBuildSettings)
        try sanitizedBuildSettings.write(to: combinedOutputURL, atomically: true, encoding: .utf8)

        let entries = try parseEntries(from: combinedOutputURL)
        try writePerTargetFiles(entries: entries, to: outputDirectory, fileManager: fileManager)
    }

    static func runCommand(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.commandFailed(errorMessage?.isEmpty == false ? errorMessage! : "xcodebuild failed.")
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw CLIError.invalidUTF8
        }

        return output
    }

    static func sanitize(_ input: String) -> String {
        var output = input

        for rule in regexReplacements {
            output = replacingMatches(in: output, pattern: rule.pattern, with: rule.replacement)
        }
        for rule in quotedValueReplacements {
            output = sanitizeQuotedValue(in: output, key: rule.key, replacement: rule.replacement)
        }

        return output
    }

    static func replacingMatches(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    static func sanitizeQuotedValue(in text: String, key: String, replacement: String) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #""\#(escapedKey)"\s*:\s*"[^"]*""#
        return replacingMatches(
            in: text,
            pattern: pattern,
            with: #""\#(key)" : "\#(replacement)""#
        )
    }

    static func parseEntries(from url: URL) throws -> [BuildSettingsEntry] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([BuildSettingsEntry].self, from: data)
    }

    static func targetBuckets(entries: [BuildSettingsEntry]) -> [String: [BuildSettingsEntry]] {
        entries.reduce(into: [String: [BuildSettingsEntry]]()) { partialResult, entry in
            guard let targetName = entry.buildSettings.targetName else { return }
            partialResult[targetName, default: []].append(entry)
        }
    }

    static func writePerTargetFiles(
        entries: [BuildSettingsEntry],
        to outputDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let buckets = targetBuckets(entries: entries)

        for targetName in buckets.keys.sorted() {
            guard let targetEntries = buckets[targetName] else { continue }
            let outputURL = outputDirectory.appendingPathComponent("\(targetName).json")
            let encoded = try encoder.encode(targetEntries)
            try encoded.write(to: outputURL)
        }
    }
}

struct BuildSettingsEntry: Codable {
    let buildSettings: BuildSettings
}

struct BuildSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case targetName = "TARGET_NAME"
    }

    let targetName: String?
}

enum CLIError: LocalizedError {
    case commandFailed(String)
    case invalidUTF8
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message
        case .invalidUTF8:
            return "xcodebuild output is not valid UTF-8."
        case let .invalidArguments(message):
            return message
        }
    }
}
