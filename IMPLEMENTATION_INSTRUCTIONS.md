# n42-dump-xcode-buildsettings: Clean Implementation Instructions

## Goal

Provide a CLI tool that exports Xcode build settings in a Git-friendly format with stable diffs.

## Core Behavior

1. Execute:

```bash
xcodebuild -alltargets -showBuildSettings -json
```

2. Sanitize volatile values in the JSON output.
3. Group entries by `buildSettings.TARGET_NAME`.
4. Write one file per target to:

```text
PersistedLogs/buildConfigs/<TARGET_NAME>.json
```

## Sanitization Rules

### Existing volatile values

- Replace timestamp-like build values:
  - Pattern: `[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}`
  - Replacement: `XXXX.XX.XX.XX.XX`
- Replace commit hash value for:
  - Key: `N42_GIT_COMMIT_HASH`
  - Example replacement value: `XXXXXXXX`
- Replace temp folder prefix under `/var/folders/.../.../` with a stable placeholder.

### Additional keys to sanitize

- `MAC_OS_X_PRODUCT_BUILD_VERSION` -> `XXXXXXXX`
- `MAC_OS_X_VERSION_ACTUAL` -> `XXXX`
- `MAC_OS_X_VERSION_MAJOR` -> `XX`
- `MAC_OS_X_VERSION_MINOR` -> `XX`
- `PATH` -> `REDACTED_PATH`

## Output File Strategy

- Do not persist an intermediate aggregate JSON file.
- Process the sanitized aggregate JSON in memory.
- Write only per-target JSON files.

## CLI / Tooling Requirements

- The binary should support `--help`.
- The package should be runnable with SwiftPM and Mint.
- Keep `--all-targets-output <path>` as a user-definable option:
  - The provided path is used to derive the output directory (its parent directory).
  - The file itself is not written.

## Quality Requirements

- Add automated tests for:
  - Sanitization rules
  - Target grouping logic
  - Per-target file generation
  - Argument parsing (`--all-targets-output`, unknown args, missing value)
- Keep the implementation refactored and readable.
- Maintain an up-to-date README that reflects actual CLI behavior.

## History Hygiene

- Changes should be organized and documented so Git history is easy to follow.
- Avoid unnecessary diff noise by sanitizing unstable build settings values.
