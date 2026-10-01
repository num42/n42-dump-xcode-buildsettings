import CryptoKit
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
        print("Usage: n42-dump-xcode-buildsettings [--all-targets-output <path>] [--redact-field <KEY> ...] [--cloned-source-packages-dir-path <path>] [--package-authorization-provider keychain|netrc] [--timeout <seconds>] [--skip-if-unchanged] [--project <path>] [--verbose]")
        print("Runs xcodebuild settings dump, sanitizes volatile values, and writes per-target JSON files.")
        print("No in-between all-targets file is written; the parent directory of --all-targets-output is used.")
        print("Use --redact-field to redact additional build setting keys with value REDACTED.")
        print("Use --cloned-source-packages-dir-path to resolve Swift packages there instead of the default DerivedData;")
        print("without it, $N42_SPM_CLONE_DIR is used when set (CI runner slots export it).")
        print("Use --package-authorization-provider to choose where xcodebuild looks up package credentials;")
        print("when $CI is set the default is netrc, so a headless machine never waits on a keychain prompt.")
        print("Use --timeout to stop xcodebuild after that many seconds (default \(BuildSettingsTool.defaultTimeoutSeconds)).")
        print("Use --skip-if-unchanged to skip the dump when the per-target files already carry the current")
        print("\(BuildSettingsTool.projectHashKey) (generated project, xcodebuild -version, tool version and redact fields);")
        print("otherwise the old per-target files are replaced, so files of deleted targets go away.")
        print("Use --project to name the .xcodeproj when the working directory does not hold exactly one.")
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
        var skipIfUnchanged = false
        /// The .xcodeproj to dump. `nil` lets xcodebuild pick the one in the
        /// working directory.
        var projectPath: String? = nil

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

    /// Part of the project hash, so a release that changes the output dumps
    /// again. Keep it in step with the release tag.
    static let version = "1.0.5"

    static let projectHashKey = "N42_PROJECT_HASH"

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
        if let project = options.projectPath {
            arguments += ["-project", project]
        }
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
        var skipIfUnchanged = false
        var projectPath: String?

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
            case "--skip-if-unchanged":
                skipIfUnchanged = true
            case "--project":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for --project.")
                }
                projectPath = arguments[index]
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
            timeoutSeconds: timeoutSeconds,
            skipIfUnchanged: skipIfUnchanged,
            projectPath: projectPath
        )
    }

    /// `xcrun` runs `/usr/bin/xcrun` with the given arguments and returns its
    /// stdout; tests replace it.
    static func run(
        options: Options = .defaults,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        xcrun: (([String]) throws -> String)? = nil
    ) throws {
        let outputDirectory = options.allTargetsOutputURL.deletingLastPathComponent()
        let logger = Logger(isVerbose: options.verbose)
        let xcrun = xcrun ?? { arguments in
            try runCommand(
                executable: "/usr/bin/xcrun",
                arguments: arguments,
                timeoutSeconds: options.timeoutSeconds,
                logger: logger
            )
        }

        logger.log("Preparing output directory: \(outputDirectory.path)")

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var projectHash: String?
        if options.skipIfUnchanged {
            let projectURL = try locateProject(path: options.projectPath, fileManager: fileManager)
            let hash = try self.projectHash(
                projectURL: projectURL,
                xcodeVersion: xcrun(["xcodebuild", "-version"]),
                additionalRedactedFields: options.additionalRedactedFields,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            logger.log("\(projectHashKey) of \(projectURL.path): \(hash)")
            if try dumpsMatch(projectHash: hash, in: outputDirectory, fileManager: fileManager) {
                print("Build settings unchanged (\(projectHashKey) \(hash)), skipping xcodebuild -showBuildSettings.")
                return
            }
            projectHash = hash
        }

        let arguments = xcodebuildArguments(options: options, environment: environment)
        logger.log("Running command: /usr/bin/xcrun \(arguments.joined(separator: " "))")
        let rawBuildSettings = try xcrun(arguments)
        logger.log("Received \(rawBuildSettings.utf8.count) bytes of build settings JSON")

        let sanitizedBuildSettings = sanitize(
            rawBuildSettings,
            additionalRedactedFields: options.additionalRedactedFields
        )
        logger.log("Sanitized JSON size: \(sanitizedBuildSettings.utf8.count) bytes")

        var entries = try parseEntries(fromJSONString: sanitizedBuildSettings)
        logger.log("Parsed \(entries.count) build settings entries")
        if let projectHash {
            entries = addingProjectHash(projectHash, to: entries)
            let removed = try removeDumps(in: outputDirectory, fileManager: fileManager)
            logger.log("Removed \(removed) old per-target JSON files")
        }
        try writePerTargetFiles(entries: entries, to: outputDirectory, fileManager: fileManager)
        logger.log("Wrote \(targetBuckets(entries: entries).count) per-target JSON files")
    }

    /// The .xcodeproj at `path`, or the only one in the working directory.
    static func locateProject(path: String?, fileManager: FileManager = .default) throws -> URL {
        if let path {
            let url = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: url.appendingPathComponent("project.pbxproj").path) else {
                throw CLIError.invalidArguments("No project.pbxproj in \(url.path).")
            }
            return url
        }
        let directory = fileManager.currentDirectoryPath
        let projects = try fileManager.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".xcodeproj") }
        guard projects.count == 1, let project = projects.first else {
            throw CLIError.invalidArguments(
                "Found \(projects.count) .xcodeproj in \(directory); name the one to hash with --project <path>."
            )
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(project)
    }

    /// SHA-256 over everything that decides the dump: the project file and
    /// shared schemes (no xcuserdata), the Xcode version (default settings
    /// come from Xcode), and this tool's version and redact fields.
    ///
    /// The project files go through the same cleanup as the dump, so the
    /// hash does not depend on the work-tree path or home directory, and
    /// values the dump redacts (XcodeGen writes the build number and commit
    /// hash into the project) do not change it either.
    static func projectHash(
        projectURL: URL,
        xcodeVersion: String,
        additionalRedactedFields: Set<String>,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let schemesURL = projectURL.appendingPathComponent("xcshareddata/xcschemes")
        let schemes = ((try? fileManager.contentsOfDirectory(atPath: schemesURL.path)) ?? [])
            .filter { $0.hasSuffix(".xcscheme") }
            .sorted()
        let files = ["project.pbxproj"] + schemes.map { "xcshareddata/xcschemes/\($0)" }

        var parts = [
            "tool \(version)",
            "redact \(additionalRedactedFields.sorted().joined(separator: ","))",
            "xcodebuild \(xcodeVersion.trimmingCharacters(in: .whitespacesAndNewlines))"
        ]
        for file in files {
            let contents = try String(contentsOf: projectURL.appendingPathComponent(file), encoding: .utf8)
            let sanitized = sanitizeProjectFile(
                contents,
                projectDirectory: projectURL.deletingLastPathComponent(),
                homeDirectory: homeDirectory,
                additionalRedactedFields: additionalRedactedFields
            )
            parts.append("\(file)\n\(sanitized)")
        }

        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Project-file counterpart of `sanitize`: the same path cleanup plus the
    /// work tree and home directory, the redacted keys in `KEY = value;`
    /// form, and XcodeGen's random object ids.
    static func sanitizeProjectFile(
        _ input: String,
        projectDirectory: URL,
        homeDirectory: String,
        additionalRedactedFields: Set<String> = []
    ) -> String {
        var output = input
        let projectPaths = Set([projectDirectory.standardizedFileURL.path, projectDirectory.resolvingSymlinksInPath().path])
        // Longest first: the work tree usually lies inside the home directory.
        for path in projectPaths.sorted(by: { $0.count > $1.count }) {
            output = output.replacingOccurrences(of: path, with: "$(PROJECT_DIR)")
        }
        if !homeDirectory.isEmpty {
            output = output.replacingOccurrences(of: homeDirectory, with: "$(HOME)")
        }
        for rule in regexReplacements {
            output = replacingMatches(in: output, pattern: rule.pattern, with: rule.replacement)
        }
        let keys = Set(quotedValueReplacements.map(\.key)).union(additionalRedactedFields)
        for key in keys.sorted() {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            output = replacingMatches(
                in: output,
                pattern: #"(?<![A-Za-z0-9_])\#(escapedKey) = (?:"(?:\\.|[^"\\])*"|[^;"]*);"#,
                with: "\(key) = REDACTED;"
            )
        }
        // XcodeGen gives some package product dependencies a random
        // "TEMP_<UUID>" id on every generation, and a project file lists its
        // objects sorted by id, so both the ids and the object order change.
        output = replacingMatches(in: output, pattern: #"TEMP_[0-9A-Fa-f-]{36}"#, with: "TEMP")
        return sortingObjectsWithinSections(output)
    }

    /// Sorts the objects (blocks starting at two tabs of indentation, up to
    /// their `};`) inside each `/* Begin … section */`. Their order only follows their ids, so
    /// nothing is lost.
    static func sortingObjectsWithinSections(_ input: String) -> String {
        var output: [String] = []
        var objects: [[String]] = []
        var inSection = false
        for line in input.components(separatedBy: "\n") {
            if line.hasPrefix("/* Begin "), line.hasSuffix(" section */") {
                output.append(line)
                inSection = true
            } else if inSection, line.hasPrefix("/* End "), line.hasSuffix(" section */") {
                output += objects.map { $0.joined(separator: "\n") }.sorted()
                output.append(line)
                objects = []
                inSection = false
            } else if inSection, line.hasPrefix("\t\t\t") || line == "\t\t};", !objects.isEmpty {
                objects[objects.count - 1].append(line)
            } else if inSection {
                objects.append([line])
            } else {
                output.append(line)
            }
        }
        output += objects.flatMap { $0 }
        return output.joined(separator: "\n")
    }

    /// Whether the output directory holds per-target files and every entry
    /// in them carries `projectHash`.
    static func dumpsMatch(projectHash: String, in directory: URL, fileManager: FileManager = .default) throws -> Bool {
        let dumps = try dumpFiles(in: directory, fileManager: fileManager)
        guard !dumps.isEmpty else { return false }
        return dumps.allSatisfy { url in
            guard
                let data = try? Data(contentsOf: url),
                let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                !entries.isEmpty
            else {
                return false
            }
            return entries.allSatisfy { entry in
                (entry["buildSettings"] as? [String: Any])?[projectHashKey] as? String == projectHash
            }
        }
    }

    static func addingProjectHash(_ projectHash: String, to entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { entry in
            guard var buildSettings = entry["buildSettings"] as? [String: Any] else { return entry }
            buildSettings[projectHashKey] = projectHash
            var entry = entry
            entry["buildSettings"] = buildSettings
            return entry
        }
    }

    /// Deletes the per-target files, so targets that no longer exist lose
    /// theirs. Returns how many were removed.
    static func removeDumps(in directory: URL, fileManager: FileManager = .default) throws -> Int {
        let dumps = try dumpFiles(in: directory, fileManager: fileManager)
        try dumps.forEach { try fileManager.removeItem(at: $0) }
        return dumps.count
    }

    static func dumpFiles(in directory: URL, fileManager: FileManager = .default) throws -> [URL] {
        try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
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
