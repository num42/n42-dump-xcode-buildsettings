# n42-dump-xcode-buildsettings

CLI tool to dump `xcodebuild` build settings, sanitize volatile values, and write one JSON file per target for stable Git diffs.

## What it does

The tool runs:

```bash
xcrun xcodebuild -alltargets -showBuildSettings -json
```

It adds `-clonedSourcePackagesDirPath` and `-packageAuthorizationProvider` when needed (see below).

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

## Swift package clones

`xcodebuild -showBuildSettings` resolves the project's Swift packages. Without a clone directory
they land in the default DerivedData, which on shared CI hosts means one multi-GB checkout per
repository and runner slot that nothing removes. Pass `--cloned-source-packages-dir-path <path>`,
or set `N42_SPM_CLONE_DIR` (the n42 runner slots export it), and the tool forwards it as
`-clonedSourcePackagesDirPath`. (`-derivedDataPath` is not an option here: xcodebuild rejects it
without a scheme.)

## Package credentials on CI

When a package needs downloading, e.g. a binary target such as MSAL's XCFramework zip, xcodebuild
looks up credentials for the download host and for the host the download redirects to. Its default
store is the login keychain. On a headless CI runner that keychain is locked, so the lookup waits for
an unlock dialog nobody answers and xcodebuild hangs without printing anything.

When `CI` is set (GitHub Actions sets it), the tool therefore passes
`-packageAuthorizationProvider netrc`, so credentials come from `~/.netrc` only. Override it with
`--package-authorization-provider keychain|netrc`.

## Timeout

The tool stops xcodebuild (and the git processes it started) after 1200 seconds (20 minutes) and
fails with an error that includes xcodebuild's last output, rather than hanging until the CI job's
own time limit. Change the limit with `--timeout <seconds>`. xcodebuild gets no stdin, so a prompt
fails instead of waiting.

## Skipping unchanged projects

`--skip-if-unchanged` skips the dump when the generated project has not changed since the last one.
The tool hashes (SHA-256) everything that decides the dump:

- the project's `project.pbxproj` and `xcshareddata/xcschemes/*.xcscheme` (not `xcuserdata`);
- `xcodebuild -version`, because the default build settings come from Xcode;
- the tool's own version and the `--redact-field` keys.

Before hashing, the project files get the same cleanup as the dump, and more, so the hash is the
same in every work tree and on every runner slot: the work-tree path and the home directory are
replaced, the redacted keys lose their values (XcodeGen writes the build number and commit hash
into the project), and XcodeGen's random `TEMP_<UUID>` object ids and the object order that follows
from them are normalised.

The hash is stored as `N42_PROJECT_HASH` in the `buildSettings` of every entry in the per-target
files. On the next run:

- If every `*.json` in the output directory carries the current hash, the tool prints that the build
  settings are unchanged and exits 0 without running `xcodebuild -showBuildSettings`.
- Otherwise it dumps, deletes the old `*.json` in the output directory (so files of deleted targets
  go away), and writes the new files with the hash.

The tool hashes the only `.xcodeproj` in the working directory. If there is none or more than one,
name it with `--project <path>`; xcodebuild then dumps that project too.

Without `--skip-if-unchanged` nothing is hashed and the output is the same as before.

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

Skipping the dump when the project is unchanged:

```bash
swift run n42-dump-xcode-buildsettings --skip-if-unchanged --redact-field N42_GIT_COMMIT_HASH
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

Skipping the dump when the project is unchanged:

```bash
mint run <owner>/n42-dump-xcode-buildsettings n42-dump-xcode-buildsettings --skip-if-unchanged --redact-field N42_GIT_COMMIT_HASH
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
