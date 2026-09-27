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
        print("Usage: n42-dump-xcode-buildsettings [--all-targets-output <path>] [--redact-field <KEY> ...] [--cloned-source-packages-dir-path <path>] [--package-authorization-provider keychain|netrc] [--timeout <seconds>] [--verbose]")
        print("Runs xcodebuild settings dump, sanitizes volatile values, and writes per-target JSON files.")
        print("No in-between all-targets file is written; the parent directory of --all-targets-output is used.")
        print("Use --redact-field to redact additional build setting keys with value REDACTED.")
        print("Use --cloned-source-packages-dir-path to resolve Swift packages there instead of the default DerivedData;")
        print("without it, $N42_SPM_CLONE_DIR is used when set (CI runner slots export it).")
        print("Use --package-authorization-provider to choose where xcodebuild looks up package credentials;")
        print("when $CI is set the default is netrc, so a headless machine never waits on a keychain prompt.")
        print("Use --timeout to stop xcodebuild after that many seconds (default \(BuildSettingsTool.defaultTimeoutSeconds)).")
        print("Use --verbose to print progress logs.")
        print("Default value: PersistedLogs/buildConfigs/allTargets.json")
    }
}

enum BuildSettingsTool {
    struct Options {
        let allTargetsOutputURL: URL
        let additionalRedactedFields: Set<String>
        let verbose: Bool
        /// Where xcodebuild resolves the project's Swift packages. `nil`
        /// means the default (DerivedData), unless `N42_SPM_CLONE_DIR` is set.
        var clonedSourcePackagesDirPath: String? = nil
        /// Credential store for package resolution (`keychain` or `netrc`).
        /// `nil` means netrc when `CI` is set, else xcodebuild's default.
        var packageAuthorizationProvider: String? = nil
        /// Seconds after which xcodebuild is stopped and the run fails.
        var timeoutSeconds: Int = BuildSettingsTool.defaultTimeoutSeconds

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

    /// Generous: a cold package resolution of a large project takes a few
    /// minutes. Without a limit a stuck resolution hangs until the CI job's
    /// own time limit, printing nothing.
    static let defaultTimeoutSeconds = 1200

    static let packageAuthorizationProviders: Set<String> = ["keychain", "netrc"]

    /// The xcodebuild invocation, with a package clone directory when one is
    /// known. `-showBuildSettings` resolves the project's Swift packages, and
    /// without a clone directory that lands in the default DerivedData: on
    /// shared CI hosts one 1.5-5 GB checkout per repository and runner slot
    /// that nothing cleans up. `-derivedDataPath` cannot be used instead;
    /// xcodebuild rejects it without a scheme.
    ///
    /// On CI the package credentials come from ~/.netrc. xcodebuild's default
    /// store is the login keychain, and a package download (a binary target
    /// such as MSAL's XCFramework zip) asks it for credentials for the
    /// download host and again for the host the download redirects to. On a
    /// headless runner the keychain is locked, so that query waits for an
    /// unlock dialog nobody answers and xcodebuild hangs without output.
    static func xcodebuildArguments(options: Options, environment: [String: String]) -> [String] {
        var arguments = xcodebuildCommand
        let fromEnvironment = environment["N42_SPM_CLONE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if let clones = options.clonedSourcePackagesDirPath ?? fromEnvironment {
            arguments += ["-clonedSourcePackagesDirPath", clones]
        }
        if let provider = options.packageAuthorizationProvider ?? (isCI(environment) ? "netrc" : nil) {
            arguments += ["-packageAuthorizationProvider", provider]
        }
        return arguments
    }

    static func isCI(_ environment: [String: String]) -> Bool {
        guard let value = environment["CI"]?.lowercased(), !value.isEmpty else { return false }
        return !["0", "false", "no"].contains(value)
    }

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
        var clonedSourcePackagesDirPath: String?
        var packageAuthorizationProvider: String?
        var timeoutSeconds = defaultTimeoutSeconds

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
            case "--cloned-source-packages-dir-path":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --cloned-source-packages-dir-path.")
                }
                clonedSourcePackagesDirPath = arguments[index]
            case "--package-authorization-provider":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --package-authorization-provider.")
                }
                guard packageAuthorizationProviders.contains(arguments[index]) else {
                    throw CLIError.invalidArguments("--package-authorization-provider must be keychain or netrc, not \(arguments[index]).")
                }
                packageAuthorizationProvider = arguments[index]
            case "--timeout":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --timeout.")
                }
                guard let seconds = Int(arguments[index]), seconds > 0 else {
                    throw CLIError.invalidArguments("--timeout needs a positive number of seconds, not \(arguments[index]).")
                }
                timeoutSeconds = seconds
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
            verbose: verbose,
            clonedSourcePackagesDirPath: clonedSourcePackagesDirPath,
            packageAuthorizationProvider: packageAuthorizationProvider,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func run(options: Options = .defaults, fileManager: FileManager = .default) throws {
        let outputDirectory = options.allTargetsOutputURL.deletingLastPathComponent()
        let logger = Logger(isVerbose: options.verbose)

        logger.log("Preparing output directory: \(outputDirectory.path)")

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let arguments = xcodebuildArguments(options: options, environment: ProcessInfo.processInfo.environment)
        logger.log("Running command: /usr/bin/xcrun \(arguments.joined(separator: " "))")
        let rawBuildSettings = try runCommand(
            executable: "/usr/bin/xcrun",
            arguments: arguments,
            timeoutSeconds: options.timeoutSeconds,
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

    static func runCommand(
        executable: String,
        arguments: [String],
        timeoutSeconds: Int = defaultTimeoutSeconds,
        logger: Logger = Logger(isVerbose: false)
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Nothing may wait for an answer on stdin: a prompt fails instead.
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

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
        if finished.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            logger.log("xcodebuild still running after \(timeoutSeconds) s, stopping it and its child processes")
            // xcodebuild's git and download children run in process groups of
            // their own and would outlive it; collect them while they are
            // still its descendants.
            let tree = [process.processIdentifier] + descendants(of: process.processIdentifier)
            tree.forEach { kill($0, SIGTERM) }
            if finished.wait(timeout: .now() + .seconds(15)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            tree.dropFirst().forEach { kill($0, SIGKILL) }
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            let errorText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw CLIError.timedOut(seconds: timeoutSeconds, stderr: errorText)
        }
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

    /// All processes below `pid`, children before grandchildren.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 1024)
        // Takes the buffer size in bytes, returns the number of pids.
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let direct = children.prefix(Int(count)).filter { $0 > 0 }
        return direct + direct.flatMap { descendants(of: $0) }
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
        let pattern = #""\#(escapedKey)"\s*:\s*"(?:\\.|[^"\\])*""#
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
    case timedOut(seconds: Int, stderr: String)

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
        case let .timedOut(seconds, stderr):
            let tail = stderr
                .split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(20)
                .joined(separator: "\n")
            return """
            xcodebuild -showBuildSettings did not finish within \(seconds) s and was stopped. \
            It resolves the project's Swift packages first, so it most likely waited for package \
            credentials (a keychain prompt nobody can answer on a headless machine), a download, or a \
            lock on the package clone directory. Use --timeout to change the limit.
            """ + (tail.isEmpty ? "" : "\nLast xcodebuild output:\n\(tail)")
        }
    }
}
