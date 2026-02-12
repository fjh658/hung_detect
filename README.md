# hung_detect 🔍

[🇺🇸 English](./README.md) | [🇨🇳 简体中文](./README.zh-CN.md)

`hung_detect` is a macOS GUI process "Not Responding" detector implemented in Swift.
It uses the same private Window Server signal used by Activity Monitor (`CGSEventIsAppUnresponsive`).

## ✨ Features

- Detects unresponsive GUI apps with the Activity Monitor style signal.
- Universal binary build (`arm64` + `x86_64`).
- macOS deployment target configurable; default is `12.0`.
- Table output for terminal and JSON output for automation.
- Includes process metadata: PID, parent PID, user, bundle ID, arch, sandbox state, sleep assertion state, uptime, executable path.
- Optional SHA-256 output.

## 🧰 Requirements

- macOS
- Xcode command line tools (`swiftc`, `xcrun`, `lipo`)

## 🏗️ Build

Build universal binary (default `MIN_MACOS=12.0`):

```bash
make build
```

Build with explicit deployment target:

```bash
make build MIN_MACOS=12.0
```

Check binary architecture and `minos`:

```bash
make check
```

Legacy wrapper (delegates to Makefile):

```bash
./build_hung_detect.sh 12.0
```

## 🍺 Homebrew Tap Install

Homebrew install uses the prebuilt binary package in `dist/` and does not compile on the end-user machine.

Tap this repository locally:

```bash
brew tap fjh658/hung-detect /path/to/hung_detect
brew install fjh658/hung-detect/hung-detect
```

Install from GitHub tap:

```bash
brew tap fjh658/hung-detect https://github.com/fjh658/hung_detect.git
brew install fjh658/hung-detect/hung-detect
```

Refresh prebuilt package before release:

```bash
make package VERSION=0.1.0 MIN_MACOS=12.0
```

## 🚀 Usage

```bash
./hung_detect
./hung_detect --all
./hung_detect --json
./hung_detect --name Chrome
./hung_detect --pid 913
```

## ⚙️ CLI Options

- `--all`, `-a`: show all matched GUI processes (default shows only not responding).
- `--sha`: include SHA-256 column in table output.
- `--pid <PID>`: filter by PID (repeatable).
- `--name <NAME>`: filter by app name or bundle ID (repeatable).
- `--json`: JSON output (always includes `sha256` field).
- `--no-color`: disable ANSI colors.
- `-h`, `--help`: show help.

## 📌 Exit Codes

- `0`: all scanned/matched processes are responding.
- `1`: at least one process is not responding.
- `2`: argument/runtime error.

## 🔒 Private API Compatibility Notes

This tool intentionally uses private APIs. Symbol locations and exported names can vary across macOS versions.
The loader includes fallback resolution for:

- `CGSMainConnectionID`, `CGSEventIsAppUnresponsive`
  - from `SkyLight` and `CoreGraphics`
  - with both plain and underscore-prefixed symbol names
- `LSASNCreateWithPid`, `LSASNExtractHighAndLowParts`
  - from `CoreServices` and `LaunchServices`
  - with `_`, plain, and `__` symbol-name variants

If all required symbols cannot be resolved, the program exits with code `2`.

## ⚡ Performance Notes

- SHA-256 is computed lazily for rows that are actually emitted.
- `--json --all` can be noticeably slower than default mode because it emits and hashes every matched process.

## 📄 License

Apache License 2.0. See `LICENSE`.
