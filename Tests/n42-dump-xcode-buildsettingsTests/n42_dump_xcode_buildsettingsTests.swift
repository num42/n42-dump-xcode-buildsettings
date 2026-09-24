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
