import Foundation
import XCTest
@testable import n42_dump_xcode_buildsettings

final class n42_dump_xcode_buildsettingsTests: XCTestCase {
    func testParseOptionsUsesDefaultOutputPath() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: [])
        XCTAssertTrue(options.allTargetsOutputURL.path.hasSuffix("PersistedLogs/buildConfigs/allTargets.json"))
    }

    func testParseOptionsAcceptsCustomAllTargetsOutputPath() throws {
        let options = try BuildSettingsTool.parseOptions(arguments: ["--all-targets-output", "/tmp/custom-all-targets.json"])
        XCTAssertEqual(options.allTargetsOutputURL.path, "/tmp/custom-all-targets.json")
    }

    func testParseOptionsThrowsForMissingValue() {
        XCTAssertThrowsError(try BuildSettingsTool.parseOptions(arguments: ["--all-targets-output"])) { error in
            XCTAssertEqual(error.localizedDescription, "Missing value for --all-targets-output.")
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

        XCTAssertTrue(output.contains("XXXX.XX.XX.XX.XX"))
        XCTAssertTrue(output.contains(#""N42_GIT_COMMIT_HASH" : "XXXXXXXX""#))
        XCTAssertTrue(output.contains("/var/folders/XX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/"))
        XCTAssertTrue(output.contains(#""MAC_OS_X_PRODUCT_BUILD_VERSION" : "XXXXXXXX""#))
        XCTAssertTrue(output.contains(#""MAC_OS_X_VERSION_ACTUAL" : "XXXX""#))
        XCTAssertTrue(output.contains(#""MAC_OS_X_VERSION_MAJOR" : "XX""#))
        XCTAssertTrue(output.contains(#""MAC_OS_X_VERSION_MINOR" : "XX""#))
        XCTAssertTrue(output.contains(#""PATH" : "REDACTED_PATH""#))
    }

    func testTargetBucketsGroupsByTargetNameAndIgnoresMissingTarget() {
        let entries = [
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: "App")),
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: "App")),
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: "Widget")),
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: nil))
        ]

        let buckets = BuildSettingsTool.targetBuckets(entries: entries)

        XCTAssertEqual(buckets["App"]?.count, 2)
        XCTAssertEqual(buckets["Widget"]?.count, 1)
        XCTAssertNil(buckets[""])
        XCTAssertEqual(buckets.keys.count, 2)
    }

    func testWritePerTargetFilesCreatesOneJSONPerTarget() throws {
        let entries = [
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: "App")),
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: "Widget")),
            BuildSettingsEntry(buildSettings: BuildSettings(targetName: "App"))
        ]

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try BuildSettingsTool.writePerTargetFiles(entries: entries, to: tempDir)

        let appURL = tempDir.appendingPathComponent("App.json")
        let widgetURL = tempDir.appendingPathComponent("Widget.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: widgetURL.path))

        let decoder = JSONDecoder()
        let appEntries = try decoder.decode([BuildSettingsEntry].self, from: Data(contentsOf: appURL))
        let widgetEntries = try decoder.decode([BuildSettingsEntry].self, from: Data(contentsOf: widgetURL))

        XCTAssertEqual(appEntries.count, 2)
        XCTAssertEqual(widgetEntries.count, 1)
    }
}
