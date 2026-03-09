# n42-dump-xcode-buildsettings

CLI tool to dump `xcodebuild` build settings, sanitize volatile values, and persist one JSON file per target for stable Git diffs.

## What it does

The tool runs:

```bash
xcodebuild -alltargets -showBuildSettings -json
```

Then it:

1. Writes a sanitized aggregate dump to `PersistedLogs/buildConfigs/allTargets.json`
2. Splits that JSON by `buildSettings.TARGET_NAME`
3. Writes one file per target: `PersistedLogs/buildConfigs/<TARGET_NAME>.json`
4. Removes `PersistedLogs/buildConfigs/allTargets.json`

## Sanitization

The dump is normalized to reduce machine- and build-specific noise.

### Regex-based replacements

- Build version timestamps like `2026.03.09.12.34` -> `XXXX.XX.XX.XX.XX`
- `"N42_GIT_COMMIT_HASH" : "1A2B3C4D"` -> `"N42_GIT_COMMIT_HASH" : "XXXXXXXX"`
- Paths under `/var/folders/.../.../` -> `/var/folders/XX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/`

### Key-specific replacements

- `MAC_OS_X_PRODUCT_BUILD_VERSION` -> `XXXXXXXX`
- `MAC_OS_X_VERSION_ACTUAL` -> `XXXX`
- `MAC_OS_X_VERSION_MAJOR` -> `XX`
- `MAC_OS_X_VERSION_MINOR` -> `XX`
- `PATH` -> `REDACTED_PATH`

## Usage

### Swift Package Manager

```bash
swift run n42-dump-xcode-buildsettings
```

Custom all-targets temporary file location:

```bash
swift run n42-dump-xcode-buildsettings --all-targets-output /tmp/allTargets.json
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

With custom all-targets output path:

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings --all-targets-output /tmp/allTargets.json
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
