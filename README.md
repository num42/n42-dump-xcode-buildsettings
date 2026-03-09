# n42-dump-xcode-buildsettings

CLI tool to dump `xcodebuild` build settings, sanitize volatile values, and write one JSON file per target for stable Git diffs.

## What it does

The tool runs:

```bash
xcrun xcodebuild -alltargets -showBuildSettings -json
```

Then it:

1. Sanitizes the full JSON dump in memory
2. Splits by `buildSettings.TARGET_NAME`
3. Writes one file per target: `<output-dir>/<TARGET_NAME>.json`

Default output dir: `PersistedLogs/buildConfigs`

## Sanitization

The dump is normalized to reduce machine- and build-specific noise.

### Regex-based replacements

- Paths under `/var/folders/.../.../` -> `/var/folders/XX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/`

### Key-specific replacements

- `MAC_OS_X_PRODUCT_BUILD_VERSION` -> `XXXXXXXX`
- `MAC_OS_X_VERSION_ACTUAL` -> `XXXX`
- `MAC_OS_X_VERSION_MAJOR` -> `XX`
- `MAC_OS_X_VERSION_MINOR` -> `XX`
- `BUILD_VERSION` -> `XXXX.XX.XX.XX.XX`
- `PATH` -> `REDACTED_PATH`

### Optional user-defined redactions

Use `--redact-field <KEY>` (repeatable) to redact additional keys with value `REDACTED`.

`N42_GIT_COMMIT_HASH` is not redacted by default; include it explicitly if needed:

```bash
swift run n42-dump-xcode-buildsettings --redact-field N42_GIT_COMMIT_HASH
```

## Usage

### Swift Package Manager

```bash
swift run n42-dump-xcode-buildsettings
```

Run from another repo:

```bash
swift run --package-path /Users/admin/dev/work/Tools/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings
```

Custom output directory (derived from parent directory of the provided path):

```bash
swift run n42-dump-xcode-buildsettings --all-targets-output /tmp/allTargets.json
```

Note: the `--all-targets-output` filename is not written. Only its parent directory is used for per-target files.

With additional redacted fields:

```bash
swift run n42-dump-xcode-buildsettings --redact-field N42_GIT_COMMIT_HASH --redact-field CUSTOM_SECRET
```

With verbose logging:

```bash
swift run n42-dump-xcode-buildsettings --verbose
```

Short form:

```bash
swift run n42-dump-xcode-buildsettings -v
```

### Mint

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings
```

With a tag:

```bash
mint run <owner>/n42-dump-xcode-buildsettings@<tag> n42-dump-xcode-buildsettings
```

Help:

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings --help
```

With custom output directory (derived from parent directory of the provided path):

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings --all-targets-output /tmp/allTargets.json
```

With additional redacted fields:

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings --redact-field N42_GIT_COMMIT_HASH --redact-field CUSTOM_SECRET
```

With verbose logging:

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings --verbose
```

Short form:

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings -v
```

## Requirements

- macOS with Xcode command line tools (`xcodebuild` and `xcrun`)
- Run from an Xcode project/workspace context where `xcodebuild -alltargets -showBuildSettings -json` succeeds

## Development

Build:

```bash
swift build
```

Test:

```bash
swift test
```
