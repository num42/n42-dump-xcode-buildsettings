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
        print("Usage: n42-dump-xcode-buildsettings [--all-targets-output <path>] [--redact-field <KEY> ...] [--verbose]")
        print("Runs xcodebuild settings dump, sanitizes volatile values, and writes per-target JSON files.")
        print("No in-between all-targets file is written; the parent directory of --all-targets-output is used.")
        print("Use --redact-field to redact additional build setting keys with value REDACTED.")
        print("Use --verbose to print progress logs.")
        print("Default value: PersistedLogs/buildConfigs/allTargets.json")
    }
}

enum BuildSettingsTool {
    struct Options {
        let allTargetsOutputURL: URL
        let additionalRedactedFields: Set<String>
        let verbose: Bool

        static let defaults = Options(
            allTargetsOutputURL: URL(fileURLWithPath: "PersistedLogs/buildConfigs/allTargets.json"),
            additionalRedactedFields: [],
            verbose: false
        )
    }

    struct Logger {
        let isVerbose: Bool

        func log(_ message: String) {
            guard isVerbose else { return }
            fputs("[n42-dump] \(message)\n", stderr)
        }
    }

    static let xcodebuildCommand: [String] = ["xcodebuild", "-alltargets", "-showBuildSettings", "-json"]

    static let regexReplacements: [(pattern: String, replacement: String)] = [
        (#"/var/folders/[a-z0-9]*/[a-z0-9_]*/"#, "/var/folders/XX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/")
    ]

    static let quotedValueReplacements: [(key: String, replacement: String)] = [
        ("BUILD_VERSION", "XXXX.XX.XX.XX.XX"),
        ("MAC_OS_X_PRODUCT_BUILD_VERSION", "XXXXXXXX"),
        ("MAC_OS_X_VERSION_ACTUAL", "XXXX"),
        ("MAC_OS_X_VERSION_MAJOR", "XX"),
        ("MAC_OS_X_VERSION_MINOR", "XX"),
        ("PATH", "REDACTED_PATH")
    ]

    static func parseOptions(arguments: [String]) throws -> Options {
        var index = 0
        var allTargetsOutputURL = Options.defaults.allTargetsOutputURL
        var additionalRedactedFields = Set<String>()
        var verbose = false

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--all-targets-output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --all-targets-output.")
                }
                allTargetsOutputURL = URL(fileURLWithPath: arguments[index])
            case "--redact-field":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --redact-field.")
                }
                additionalRedactedFields.insert(arguments[index])
            case "--verbose", "-v":
                verbose = true
            default:
                throw CLIError.invalidArguments("Unknown argument: \(argument)")
            }
            index += 1
        }

        return Options(
            allTargetsOutputURL: allTargetsOutputURL,
            additionalRedactedFields: additionalRedactedFields,
            verbose: verbose
        )
    }

    static func run(options: Options = .defaults, fileManager: FileManager = .default) throws {
        let outputDirectory = options.allTargetsOutputURL.deletingLastPathComponent()
        let logger = Logger(isVerbose: options.verbose)

        logger.log("Preparing output directory: \(outputDirectory.path)")

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        logger.log("Running command: /usr/bin/xcrun \(xcodebuildCommand.joined(separator: " "))")
        let rawBuildSettings = try runCommand(
            executable: "/usr/bin/xcrun",
            arguments: xcodebuildCommand,
            logger: logger
        )
        logger.log("Received \(rawBuildSettings.utf8.count) bytes of build settings JSON")

        let sanitizedBuildSettings = sanitize(
            rawBuildSettings,
            additionalRedactedFields: options.additionalRedactedFields
        )
        logger.log("Sanitized JSON size: \(sanitizedBuildSettings.utf8.count) bytes")

        let entries = try parseEntries(fromJSONString: sanitizedBuildSettings)
        logger.log("Parsed \(entries.count) build settings entries")
        try writePerTargetFiles(entries: entries, to: outputDirectory, fileManager: fileManager)
        logger.log("Wrote \(targetBuckets(entries: entries).count) per-target JSON files")
    }

    static func runCommand(executable: String, arguments: [String], logger: Logger = Logger(isVerbose: false)) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let fileManager = FileManager.default
        let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("n42-dump-stdout-\(UUID().uuidString).tmp")
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("n42-dump-stderr-\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        stdoutHandle.closeFile()
        stderrHandle.closeFile()

        let outputData = try Data(contentsOf: stdoutURL)
        let errorData = try Data(contentsOf: stderrURL)

        if logger.isVerbose, !errorData.isEmpty, let stderrText = String(data: errorData, encoding: .utf8) {
            logger.log("xcodebuild stderr output:\n\(stderrText)")
        }

        guard process.terminationStatus == 0 else {
            logger.log("xcodebuild exited with status \(process.terminationStatus)")
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.commandFailed(errorMessage?.isEmpty == false ? errorMessage! : "xcodebuild failed.")
        }

        logger.log("xcodebuild completed successfully")

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw CLIError.invalidUTF8
        }

        return output
    }

    static func sanitize(_ input: String, additionalRedactedFields: Set<String> = []) -> String {
        var output = input

        for rule in regexReplacements {
            output = replacingMatches(in: output, pattern: rule.pattern, with: rule.replacement)
        }
        for rule in quotedValueReplacements {
            output = sanitizeQuotedValue(in: output, key: rule.key, replacement: rule.replacement)
        }
        for field in additionalRedactedFields.sorted() {
            output = sanitizeQuotedValue(in: output, key: field, replacement: "REDACTED")
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

    static func parseEntries(fromJSONString jsonString: String) throws -> [[String: Any]] {
        guard let data = jsonString.data(using: .utf8) else {
            throw CLIError.invalidUTF8
        }

        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CLIError.invalidJSONStructure
        }
        return jsonArray
    }

    static func targetBuckets(entries: [[String: Any]]) -> [String: [[String: Any]]] {
        entries.reduce(into: [String: [[String: Any]]]()) { partialResult, entry in
            guard
                let buildSettings = entry["buildSettings"] as? [String: Any],
                let targetName = buildSettings["TARGET_NAME"] as? String
            else {
                return
            }
            partialResult[targetName, default: []].append(entry)
        }
    }

    static func writePerTargetFiles(
        entries: [[String: Any]],
        to outputDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let buckets = targetBuckets(entries: entries)

        for targetName in buckets.keys.sorted() {
            guard let targetEntries = buckets[targetName] else { continue }
            let outputURL = outputDirectory.appendingPathComponent("\(targetName).json")
            let encoded = try JSONSerialization.data(
                withJSONObject: targetEntries,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try encoded.write(to: outputURL, options: .atomic)
        }
    }
}

enum CLIError: LocalizedError {
    case commandFailed(String)
    case invalidUTF8
    case invalidJSONStructure
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message
        case .invalidUTF8:
            return "xcodebuild output is not valid UTF-8."
        case .invalidJSONStructure:
            return "xcodebuild output JSON has an unexpected structure."
        case let .invalidArguments(message):
            return message
        }
    }
}
