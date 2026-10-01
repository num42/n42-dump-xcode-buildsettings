import Foundation
import XCTest
@testable import n42_dump_xcode_buildsettings

final class n42_dump_xcode_buildsettingsTests: XCTestCase {
    func testParseOptionsUsesDefaultOutputPath() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: [])
        XCTAssertTrue(options.allTargetsOutputURL.path.hasSuffix("PersistedLogs/buildConfigs/allTargets.json"))
        XCTAssertTrue(options.additionalRedactedFields.isEmpty)
        XCTAssertFalse(options.verbose)
    }

    func testParseOptionsAcceptsCustomAllTargetsOutputPath() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: ["--all-targets-output", "/tmp/custom-all-targets.json"])
        XCTAssertEqual(options.allTargetsOutputURL.path, "/tmp/custom-all-targets.json")
    }

    func testParseOptionsAcceptsRepeatedRedactFieldFlags() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: [
            "--redact-field", "N42_GIT_COMMIT_HASH",
            "--redact-field", "FOO",
            "--redact-field", "N42_GIT_COMMIT_HASH"
        ])
        XCTAssertEqual(options.additionalRedactedFields, Set(["N42_GIT_COMMIT_HASH", "FOO"]))
    }

    func testParseOptionsAcceptsVerboseFlag() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: ["--verbose"])
        XCTAssertTrue(options.verbose)
    }

    func testParseOptionsAcceptsClonedSourcePackagesDirPath() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: ["--cloned-source-packages-dir-path", "/tmp/clones"])
        XCTAssertEqual(options.clonedSourcePackagesDirPath, "/tmp/clones")
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--cloned-source-packages-dir-path"])) { error in
            XCTAssertEqual(error.localizedDescription, "Missing value for --cloned-source-packages-dir-path.")
        }
    }

    func testXcodebuildArgumentsPinPackageClonesWhenADirectoryIsKnown() throws {
        let base = ["xcodebuild", "-alltargets", "-showBuildSettings", "-json"]
        let defaults = try BuildSettingsTool.parseOptions(arguments: [])
        XCTAssertEqual(BuildSettingsTool.xcodebuildArguments(options: defaults, environment: [:]), base)
        XCTAssertEqual(BuildSettingsTool.xcodebuildArguments(options: defaults, environment: ["N42_SPM_CLONE_DIR": ""]), base)
        XCTAssertEqual(
            BuildSettingsTool.xcodebuildArguments(options: defaults, environment: ["N42_SPM_CLONE_DIR": "/slots/slot-1/cache/swiftpm-clones"]),
            base + ["-clonedSourcePackagesDirPath", "/slots/slot-1/cache/swiftpm-clones"]
        )
        let explicit = try BuildSettingsTool.parseOptions(arguments: ["--cloned-source-packages-dir-path", "/tmp/clones"])
        XCTAssertEqual(
            BuildSettingsTool.xcodebuildArguments(options: explicit, environment: ["N42_SPM_CLONE_DIR": "/env/clones"]),
            base + ["-clonedSourcePackagesDirPath", "/tmp/clones"],
            "the option wins over the environment"
        )
        XCTAssertFalse(
            BuildSettingsTool.xcodebuildArguments(options: explicit, environment: [:]).contains("-derivedDataPath"),
            "xcodebuild rejects -derivedDataPath without a scheme"
        )
    }

    func testXcodebuildArgumentsUseNetrcCredentialsOnCI() throws {
        let base = ["xcodebuild", "-alltargets", "-showBuildSettings", "-json"]
        let defaults = try BuildSettingsTool.parseOptions(arguments: [])
        XCTAssertEqual(
            BuildSettingsTool.xcodebuildArguments(options: defaults, environment: ["CI": "true"]),
            base + ["-packageAuthorizationProvider", "netrc"],
            "a headless CI machine cannot answer a keychain prompt"
        )
        XCTAssertEqual(BuildSettingsTool.xcodebuildArguments(options: defaults, environment: ["CI": "false"]), base)
        XCTAssertEqual(BuildSettingsTool.xcodebuildArguments(options: defaults, environment: ["CI": ""]), base)
        XCTAssertEqual(
            BuildSettingsTool.xcodebuildArguments(
                options: defaults,
                environment: ["CI": "1", "N42_SPM_CLONE_DIR": "/slots/slot-3/cache/swiftpm"]
            ),
            base + ["-clonedSourcePackagesDirPath", "/slots/slot-3/cache/swiftpm", "-packageAuthorizationProvider", "netrc"]
        )
        let keychain = try BuildSettingsTool.parseOptions(arguments: ["--package-authorization-provider", "keychain"])
        XCTAssertEqual(
            BuildSettingsTool.xcodebuildArguments(options: keychain, environment: ["CI": "true"]),
            base + ["-packageAuthorizationProvider", "keychain"],
            "the option wins over the CI default"
        )
    }

    func testParseOptionsValidatesPackageAuthorizationProviderAndTimeout() throws {
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--package-authorization-provider", "ssh"])) { error in
            XCTAssertEqual(error.localizedDescription, "--package-authorization-provider must be keychain or netrc, not ssh.")
        }
        XCTAssertEqual(try BuildSettingsTool.parseOptions(arguments: []).timeoutSeconds, BuildSettingsTool.defaultTimeoutSeconds)
        XCTAssertEqual(try BuildSettingsTool.parseOptions(arguments: ["--timeout", "90"]).timeoutSeconds, 90)
        for value in ["0", "-5", "soon"] {
            XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--timeout", value])) { error in
                XCTAssertEqual(error.localizedDescription, "--timeout needs a positive number of seconds, not \(value).")
            }
        }
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--timeout"])) { error in
            XCTAssertEqual(error.localizedDescription, "Missing value for --timeout.")
        }
    }

    func testRunCommandStopsAHangingCommandAndReportsIt() throws {
        let start = Date()
        XCTAssertThrowsError(
            try BuildSettingsTool.runCommand(
                executable: "/bin/sh",
                arguments: ["-c", "echo resolving packages >&2; sleep 60"],
                timeoutSeconds: 1
            )
        ) { error in
            guard case let CLIError.timedOut(seconds, stderr) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(seconds, 1)
            XCTAssertEqual(stderr, "resolving packages\n")
            XCTAssertTrue(error.localizedDescription.contains("did not finish within 1 s"))
            XCTAssertTrue(error.localizedDescription.hasSuffix("Last xcodebuild output:\nresolving packages"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    func testRunCommandAlsoStopsTheChildProcessesOfAHangingCommand() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("n42-dump-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // The child is started in the background, like xcodebuild's git
        // processes, and writes its pid for the test to check.
        XCTAssertThrowsError(
            try BuildSettingsTool.runCommand(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 60 & echo $! > '\(marker.path)'; wait"],
                timeoutSeconds: 1
            )
        )
        let childPID = try XCTUnwrap(pid_t(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(childPID, 0), -1, "the background child was left running")
    }

    func testRunCommandGivesTheCommandNoStdin() throws {
        // cat would block forever on an inherited terminal or pipe.
        XCTAssertEqual(try BuildSettingsTool.runCommand(executable: "/bin/cat", arguments: [], timeoutSeconds: 10), "")
    }

    func testParseOptionsThrowsForMissingValue() {
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--all-targets-output"])) { error in
            XCTAssertEqual(error.localizedDescription, "Missing value for --all-targets-output.")
        }
    }

    func testParseOptionsThrowsForMissingRedactFieldValue() {
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--redact-field"])) { error in
            XCTAssertEqual(error.localizedDescription, "Missing value for --redact-field.")
        }
    }

    func testParseOptionsThrowsForUnknownArgument() {
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--unknown"])) { error in
            XCTAssertEqual(error.localizedDescription, "Unknown argument: --unknown")
        }
    }

    func testSanitizeReplacesConfiguredPatterns() {
        let input = """
        {
          "BUILD_VERSION" : "2026.03.09.12.34",
          "UNRELATED_VERSION" : "2026.03.09.12.34",
          "N42_GIT_COMMIT_HASH" : "1A2B3C4D",
          "TMPDIR" : "/var/folders/ab/cd_efghijklmnopqrstu/",
          "MAC_OS_X_PRODUCT_BUILD_VERSION" : "24B81",
          "MAC_OS_X_VERSION_ACTUAL" : "150200",
          "MAC_OS_X_VERSION_MAJOR" : "150000",
          "MAC_OS_X_VERSION_MINOR" : "150200",
          "PATH" : "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        """

        let output = BuildSettingsTool.sanitize(input)

        XCTAssertTrue(output.contains(#""BUILD_VERSION" : "XXXX.XX.XX.XX.XX""#))
        XCTAssertTrue(output.contains(#""UNRELATED_VERSION" : "2026.03.09.12.34""#))
        XCTAssertTrue(output.contains(#""N42_GIT_COMMIT_HASH" : "1A2B3C4D""#))
        XCTAssertTrue(output.contains("/var/folders/XX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/"))
        XCTAssertTrue(output.contains(#""MAC_OS_X_PRODUCT_BUILD_VERSION" : "XXXXXXXX""#))
        XCTAssertTrue(output.contains(#""MAC_OS_X_VERSION_ACTUAL" : "XXXX""#))
        XCTAssertTrue(output.contains(#""MAC_OS_X_VERSION_MAJOR" : "XX""#))
        XCTAssertTrue(output.contains(#""MAC_OS_X_VERSION_MINOR" : "XX""#))
        XCTAssertTrue(output.contains(#""PATH" : "REDACTED_PATH""#))
    }

    func testSanitizeRedactsUserProvidedFields() {
        let input = """
        {
          "N42_GIT_COMMIT_HASH" : "1A2B3C4D",
          "CUSTOM_SECRET" : "abc123",
          "VERSION_INFO_STRING" : "\\"@(#)PROGRAM:AppModule  PROJECT:ClinicApp-1\\""
        }
        """

        let output = BuildSettingsTool.sanitize(
            input,
            additionalRedactedFields: ["N42_GIT_COMMIT_HASH", "CUSTOM_SECRET", "VERSION_INFO_STRING"]
        )

        XCTAssertTrue(output.contains(#""N42_GIT_COMMIT_HASH" : "REDACTED""#))
        XCTAssertTrue(output.contains(#""CUSTOM_SECRET" : "REDACTED""#))
        XCTAssertTrue(output.contains(#""VERSION_INFO_STRING" : "REDACTED""#))
    }

    func testTargetBucketsGroupsByTargetNameAndIgnoresMissingTarget() {
        let entries: [[String: Any]] = [
            ["buildSettings": ["TARGET_NAME": "App"]],
            ["buildSettings": ["TARGET_NAME": "App"]],
            ["buildSettings": ["TARGET_NAME": "Widget"]],
            ["buildSettings": ["OTHER": "value"]]
        ]

        let buckets = BuildSettingsTool.targetBuckets(entries: entries)

        XCTAssertEqual(buckets["App"]?.count, 2)
        XCTAssertEqual(buckets["Widget"]?.count, 1)
        XCTAssertNil(buckets[""])
        XCTAssertEqual(buckets.keys.count, 2)
    }

    func testWritePerTargetFilesCreatesOneJSONPerTarget() throws {
        let entries: [[String: Any]] = [
            ["target": "AppModule", "buildSettings": ["TARGET_NAME": "App", "PATH": "value1"]],
            ["target": "WidgetModule", "buildSettings": ["TARGET_NAME": "Widget", "PATH": "value2"]],
            ["target": "AppModule", "buildSettings": ["TARGET_NAME": "App", "OTHER_KEY": "keep-me"]]
        ]

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try BuildSettingsTool.writePerTargetFiles(entries: entries, to: tempDir)

        let appURL = tempDir.appendingPathComponent("App.json")
        let widgetURL = tempDir.appendingPathComponent("Widget.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: widgetURL.path))

        let appObject = try JSONSerialization.jsonObject(with: Data(contentsOf: appURL))
        let widgetObject = try JSONSerialization.jsonObject(with: Data(contentsOf: widgetURL))
        guard let appEntries = appObject as? [[String: Any]] else {
            return XCTFail("App.json is not an array of objects")
        }
        guard let widgetEntries = widgetObject as? [[String: Any]] else {
            return XCTFail("Widget.json is not an array of objects")
        }

        XCTAssertEqual(appEntries.count, 2)
        XCTAssertEqual(widgetEntries.count, 1)

        let appFirst = try XCTUnwrap(appEntries.first)
        let appBuildSettings = try XCTUnwrap(appFirst["buildSettings"] as? [String: Any])
        XCTAssertEqual(appBuildSettings["TARGET_NAME"] as? String, "App")
        XCTAssertEqual(appBuildSettings["PATH"] as? String, "value1")
        XCTAssertEqual(appFirst["target"] as? String, "AppModule")
    }

    func testParseOptionsAcceptsSkipIfUnchangedAndProject() throws {
        let defaults = try BuildSettingsTool.parseOptions(arguments: [])
        XCTAssertFalse(defaults.skipIfUnchanged)
        XCTAssertNil(defaults.projectPath)

        let options = try BuildSettingsTool.parseOptions(arguments: ["--skip-if-unchanged", "--project", "App.xcodeproj"])
        XCTAssertTrue(options.skipIfUnchanged)
        XCTAssertEqual(options.projectPath, "App.xcodeproj")
        XCTAssertEqual(
            BuildSettingsTool.xcodebuildArguments(options: options, environment: [:]),
            ["xcodebuild", "-alltargets", "-showBuildSettings", "-json", "-project", "App.xcodeproj"]
        )
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--project"])) { error in
            XCTAssertEqual(error.localizedDescription, "Missing value for --project.")
        }
    }

    func testProjectHashIsStableAcrossWorkTreePathsAndRedactedValues() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeProject(in: root.appendingPathComponent("slot-1/_work/app/iOS"), build: "2026.10.01.09.44", commit: "7F622FE5")
        let second = try makeProject(in: root.appendingPathComponent("slot-2/other/_work/app/iOS"), build: "2026.10.02.11.05", commit: "0A1B2C3D")
        try writeFile(first.appendingPathComponent("xcuserdata/someone.xcuserdatad/xcschemes/xcschememanagement.plist"), "first")
        try writeFile(second.appendingPathComponent("xcuserdata/other.xcuserdatad/xcschemes/xcschememanagement.plist"), "second")

        let redacted: Set<String> = ["CURRENT_PROJECT_VERSION", "N42_GIT_COMMIT_HASH"]
        func hash(_ project: URL, xcode: String = "Xcode 27.0\nBuild version 27A100", redact: Set<String> = redacted, home: String? = nil) throws -> String {
            try BuildSettingsTool.projectHash(
                projectURL: project,
                xcodeVersion: xcode,
                additionalRedactedFields: redact,
                homeDirectory: home ?? project.deletingLastPathComponent().deletingLastPathComponent().path
            )
        }

        XCTAssertEqual(try hash(first), try hash(second))
        XCTAssertEqual(try hash(first).count, 64)

        XCTAssertNotEqual(try hash(first), try hash(first, xcode: "Xcode 27.1\nBuild version 27B50"))
        XCTAssertNotEqual(try hash(first), try hash(first, redact: redacted.union(["MARKETING_VERSION"])))
        XCTAssertNotEqual(
            try hash(first, redact: ["N42_GIT_COMMIT_HASH"]),
            try hash(second, redact: ["N42_GIT_COMMIT_HASH"]),
            "the build numbers differ and are not redacted"
        )

        let unchanged = try hash(first)
        try writeFile(first.appendingPathComponent("xcshareddata/xcschemes/App.xcscheme"), "<Scheme version = \"2.0\"/>")
        XCTAssertNotEqual(try hash(first), unchanged, "a scheme changed")

        let schemeChanged = try hash(first)
        let pbxproj = first.appendingPathComponent("project.pbxproj")
        try writeFile(pbxproj, try String(contentsOf: pbxproj, encoding: .utf8) + "/* New.swift in Sources */\n")
        XCTAssertNotEqual(try hash(first), schemeChanged, "a source file was added")
    }

    func testSanitizeProjectFileIgnoresXcodeGensRandomObjectIDs() {
        func project(_ first: String, _ second: String) -> String {
            let objects = [
                (first, "Columnifier"),
                (second, "Changeable"),
            ].sorted { $0.0 < $1.0 }.map { id, name in
                "\t\t\"TEMP_\(id)\" /* \(name) */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = \(name);\n\t\t};"
            }
            return """
            /* Begin PBXTargetDependency section */
            \t\t019F062F70FB6E8647486FB7 /* PBXTargetDependency */ = {
            \t\t\tisa = PBXTargetDependency;
            \t\t\tproductRef = "TEMP_\(first)" /* Columnifier */;
            \t\t};
            /* End PBXTargetDependency section */

            /* Begin XCSwiftPackageProductDependency section */
            \(objects.joined(separator: "\n"))
            /* End XCSwiftPackageProductDependency section */

            """
        }
        func sanitized(_ text: String) -> String {
            BuildSettingsTool.sanitizeProjectFile(text, projectDirectory: URL(fileURLWithPath: "/work"), homeDirectory: "/home")
        }

        let generated = project("32C715C3-160D-40A5-B027-19AE24C08914", "F22DC62E-1093-4727-A706-F85B03674BB8")
        let regenerated = project("D7F5229A-0EE2-454D-B411-C948CC201C2C", "18E489B1-237F-4E34-814F-B1184D9F5E6F")
        XCTAssertNotEqual(generated, regenerated)
        XCTAssertEqual(sanitized(generated), sanitized(regenerated))
        XCTAssertNotEqual(sanitized(generated), sanitized(generated.replacingOccurrences(of: "productName = Changeable", with: "productName = Other")))
    }

    func testRunSkipsTheDumpWhenEveryFileCarriesTheProjectHash() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root.appendingPathComponent("iOS"), build: "1", commit: "AAAA")
        let output = root.appendingPathComponent("iOS/PersistedLogs/buildConfigs")
        let xcrun = FakeXcrun(targets: ["App", "Widget"])
        let options = try skipOptions(project: project, output: output)

        try BuildSettingsTool.run(options: options, homeDirectory: root.path, xcrun: xcrun.run)
        XCTAssertEqual(xcrun.dumps, 1)
        let hash = try XCTUnwrap(projectHash(in: output.appendingPathComponent("App.json")))
        XCTAssertEqual(try projectHash(in: output.appendingPathComponent("Widget.json")), hash)
        let written = try Data(contentsOf: output.appendingPathComponent("App.json"))

        // A new build number and commit only change redacted values.
        try makeProject(in: root.appendingPathComponent("iOS"), build: "2", commit: "BBBB")
        try BuildSettingsTool.run(options: options, homeDirectory: root.path, xcrun: xcrun.run)
        XCTAssertEqual(xcrun.dumps, 1, "xcodebuild -showBuildSettings ran although nothing changed")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("App.json")), written)
    }

    func testRunDumpsAgainWhenAHashIsMissingOrDifferent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root.appendingPathComponent("iOS"), build: "1", commit: "AAAA")
        let output = root.appendingPathComponent("iOS/PersistedLogs/buildConfigs")
        let xcrun = FakeXcrun(targets: ["App", "Widget"])
        let options = try skipOptions(project: project, output: output)

        // Files from a release without the hash.
        try BuildSettingsTool.run(options: try BuildSettingsTool.parseOptions(arguments: [
            "--all-targets-output", output.appendingPathComponent("allTargets.json").path
        ]), xcrun: xcrun.run)
        XCTAssertNil(try projectHash(in: output.appendingPathComponent("App.json")))
        XCTAssertEqual(xcrun.versionQueries, 0, "without --skip-if-unchanged nothing is hashed")

        try BuildSettingsTool.run(options: options, homeDirectory: root.path, xcrun: xcrun.run)
        XCTAssertEqual(xcrun.dumps, 2)
        let firstHash = try XCTUnwrap(projectHash(in: output.appendingPathComponent("App.json")))

        // One file without the hash is enough to dump again.
        try writeFile(output.appendingPathComponent("Widget.json"), #"[{"buildSettings":{"TARGET_NAME":"Widget"}}]"#)
        try BuildSettingsTool.run(options: options, homeDirectory: root.path, xcrun: xcrun.run)
        XCTAssertEqual(xcrun.dumps, 3)
        XCTAssertEqual(try projectHash(in: output.appendingPathComponent("Widget.json")), firstHash)

        xcrun.xcodeVersion = "Xcode 27.1\nBuild version 27B50"
        try BuildSettingsTool.run(options: options, homeDirectory: root.path, xcrun: xcrun.run)
        XCTAssertEqual(xcrun.dumps, 4)
        XCTAssertNotEqual(try projectHash(in: output.appendingPathComponent("App.json")), firstHash)
    }

    func testRunRemovesTheFilesOfDeletedTargets() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root.appendingPathComponent("iOS"), build: "1", commit: "AAAA")
        let output = root.appendingPathComponent("iOS/PersistedLogs/buildConfigs")
        try writeFile(output.appendingPathComponent("Removed.json"), #"[{"buildSettings":{"TARGET_NAME":"Removed"}}]"#)
        try writeFile(output.appendingPathComponent("README.txt"), "kept")

        try BuildSettingsTool.run(
            options: try skipOptions(project: project, output: output),
            homeDirectory: root.path,
            xcrun: FakeXcrun(targets: ["App"]).run
        )

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(),
            ["App.json", "README.txt"]
        )
    }

    func testLocateProjectNeedsExactlyOneProjectWithoutTheOption() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root, build: "1", commit: "AAAA")
        XCTAssertEqual(try BuildSettingsTool.locateProject(path: project.path).path, project.path)
        XCTAssertThrowsError(try BuildSettingsTool.locateProject(path: root.appendingPathComponent("Missing.xcodeproj").path))

        let previous = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        FileManager.default.changeCurrentDirectoryPath(root.path)
        XCTAssertEqual(try BuildSettingsTool.locateProject(path: nil).lastPathComponent, "App.xcodeproj")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Other.xcodeproj"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try BuildSettingsTool.locateProject(path: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("--project"))
        }
    }

    // MARK: - Helpers

    private final class FakeXcrun {
        let targets: [String]
        var xcodeVersion = "Xcode 27.0\nBuild version 27A100"
        private(set) var dumps = 0
        private(set) var versionQueries = 0

        init(targets: [String]) {
            self.targets = targets
        }

        func run(_ arguments: [String]) throws -> String {
            if arguments == ["xcodebuild", "-version"] {
                versionQueries += 1
                return xcodeVersion + "\n"
            }
            XCTAssertTrue(arguments.contains("-showBuildSettings"), "unexpected call \(arguments)")
            dumps += 1
            let entries = targets.map { #"{"action":"build","target":"\#($0)","buildSettings":{"TARGET_NAME":"\#($0)","PATH":"/usr/bin"}}"# }
            return "[" + entries.joined(separator: ",") + "]"
        }
    }

    private func skipOptions(project: URL, output: URL) throws -> BuildSettingsTool.Options {
        try BuildSettingsTool.parseOptions(arguments: [
            "--skip-if-unchanged",
            "--project", project.path,
            "--all-targets-output", output.appendingPathComponent("allTargets.json").path,
            "--redact-field", "CURRENT_PROJECT_VERSION",
            "--redact-field", "N42_GIT_COMMIT_HASH"
        ])
    }

    /// A generated-looking project whose files mention the work tree, the
    /// home directory and the volatile values XcodeGen writes.
    @discardableResult
    private func makeProject(in directory: URL, build: String, commit: String) throws -> URL {
        let project = directory.appendingPathComponent("App.xcodeproj")
        let home = directory.deletingLastPathComponent().path
        try writeFile(project.appendingPathComponent("project.pbxproj"), """
        // !$*UTF8*$!
        {
        \t\t\t\tshellScript = "export PATH=\\"\(home)/.rbenv/shims:$PATH\\"\\n";
        \t\t\t\tCURRENT_PROJECT_VERSION = \(build);
        \t\t\t\tN42_GIT_COMMIT_HASH = "\(commit)";
        \t\t\t\tINFOPLIST_FILE = "\(directory.path)/Sources/Info.plist";
        \t\t\t\tPRODUCT_NAME = App;
        }

        """)
        try writeFile(project.appendingPathComponent("xcshareddata/xcschemes/App.xcscheme"), """
        <Scheme version = "1.7"><PathRunnable FilePath = "\(directory.path)/App.app"/></Scheme>
        """)
        return project
    }

    private func projectHash(in file: URL) throws -> String? {
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        return (entries.first?["buildSettings"] as? [String: Any])?[BuildSettingsTool.projectHashKey] as? String
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
