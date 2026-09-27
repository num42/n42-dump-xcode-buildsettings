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
}
