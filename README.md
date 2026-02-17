# hung_detect 🔍

[🇺🇸 English](./README.md) | [🇨🇳 简体中文](./README.zh-CN.md)

`hung_detect` is a macOS GUI process "Not Responding" detector implemented in Swift.
It uses the same private Window Server signal used by Activity Monitor (`CGSEventIsAppUnresponsive`).

## ✨ Features

- Detects unresponsive GUI apps with the Activity Monitor style signal.
- Universal binary build (`arm64` + `x86_64`).
- macOS deployment target is defined in `Package.swift` (`macOS 12+`).
- Table output for terminal and JSON output for automation.
- Includes process metadata: PID, parent PID, user, bundle ID, arch, sandbox state, sleep assertion state, uptime, executable path.
- Optional SHA-256 output.
- **Monitor mode**: continuous push+poll monitoring for hung state changes (NDJSON event stream).
- **Built-in diagnosis**: automatically run `sample` and `spindump` on hung processes.

## 🧰 Requirements

- macOS
- Xcode command line tools (`swift`, `xcrun`)

## 🏗️ Build

Build universal binary:

```bash
make build
```

Check binary architecture and `minos`:

```bash
make check
```

Legacy wrapper (delegates to Makefile):

```bash
./build_hung_detect.sh
```

## 🍺 Homebrew Tap Install

Homebrew install uses the prebuilt binary package in `dist/` and does not compile on the end-user machine.

Tap this repository locally:

```bash
brew tap fjh658/hung-detect /path/to/hung_detect
brew install hung-detect
```

Install from GitHub tap:

```bash
brew tap fjh658/hung-detect https://github.com/fjh658/hung_detect.git
brew install hung-detect
```

Refresh prebuilt package before release:

```bash
make package
```

`make package` also refreshes `Formula/hung-detect.rb` from `Formula/hung-detect.rb.tmpl`, injecting the current version (from `Sources/hung_detect/Version.swift`) and tarball `sha256`.

## 🚀 Usage

```bash
./hung_detect                             # Detect hung apps (exit 1 if any)
./hung_detect --all                       # List all GUI apps with details
./hung_detect --json                      # Machine-readable JSON output
./hung_detect --name Chrome               # Show Chrome processes
./hung_detect --pid 913                   # Show specific PID

# Monitor mode
./hung_detect --monitor                   # Watch for hung state changes
./hung_detect -m --json | jq .            # Stream events as NDJSON
./hung_detect -m --name Safari --interval 2  # Monitor Safari every 2s

# Diagnosis
./hung_detect --sample                    # Detect + sample hung processes
sudo ./hung_detect --full --spindump-duration 5 --spindump-system-duration 5  # Full diagnosis with 5s spindumps
./hung_detect -m --sample                 # Monitor + auto-diagnose on hung
sudo ./hung_detect -m --full              # Monitor + full auto-diagnose on hung
sudo ./hung_detect -m --full --spindump-duration 5 --spindump-system-duration 5  # Monitor + full with 5s spindumps
```

## 🖼️ Screenshots

### Table Output

![hung_detect table output](images/hung_detect.png)

### JSON Output

![hung_detect json output](images/hung_detect_json.png)

## ⚙️ CLI Options

**Detection:**
- `--all`, `-a`: show all matched GUI processes (default shows only not responding).
- `--sha`: include SHA-256 column in table output.
- `--pid <PID>`: filter by PID (repeatable).
- `--name <NAME>`: filter by app name or bundle ID (repeatable).
- `--json`: JSON output (always includes `sha256` field).
- `--no-color`: disable ANSI colors.
- `-v`, `--version`: show version.
- `-h`, `--help`: show help.

**Monitor:**
- `--monitor`, `-m`: continuous monitoring mode (Ctrl+C to stop).
- `--interval <SECS>`: polling interval for monitor mode (default: 3, min: 0.5).

**Diagnosis:**
- `--sample`: run `sample` on each hung process.
- `--spindump`: also run per-process spindump (implies `--sample`, needs root).
- `--full`: also run system-wide spindump (implies `--spindump`, needs root).
- Scope: diagnosis options apply in both single-shot and monitor (`-m`) modes.
- Strict mode: `--spindump` / `--full` fail fast at startup if spindump privilege is unavailable.
- Sudo ownership: when run via `sudo`, output directory/files are chowned back to the real user (no root-owned dump artifacts).
- `--duration <SECS>`: legacy shortcut to set all diagnosis durations at once.
- `--sample-duration <SECS>`: `sample` duration in seconds (default: 10, min: 1).
- `--sample-interval-ms <MS>`: `sample` interval in milliseconds (default: 1, min: 1).
- `--spindump-duration <SECS>`: per-process `spindump` duration in seconds (default: 10, min: 1).
- `--spindump-interval-ms <MS>`: per-process `spindump` interval in milliseconds (default: 10, min: 1).
- `--spindump-system-duration <SECS>`: system-wide `spindump` duration for `--full` (default: 10, min: 1).
- `--spindump-system-interval-ms <MS>`: system-wide `spindump` interval for `--full` (default: 10, min: 1).
- `--outdir <DIR>`: output directory (default: `./hung_diag_<timestamp>`).

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

## 🩺 Diagnosis

Diagnosis functionality is built into `hung_detect`. When hung processes are found, it can automatically collect `sample` and `spindump` data in parallel.

### Three Diagnosis Levels

| Level | Flag | Tools | Requires root |
|---|---|---|---|
| 1 | `--sample` | per-process `sample` | No |
| 2 | `--spindump` | + per-process `spindump` | Yes |
| 3 | `--full` | + system-wide `spindump` | Yes |

### Output Files

Saved to `hung_diag_<timestamp>/` (or `--outdir`) with timestamped filenames:

```
hung_diag_20260214_142312/
├── 20260214_142312_AlDente_913.sample.txt
├── 20260214_142312_AlDente_913.spindump.txt
└── 20260214_142312_system.spindump.txt
```

### Monitor + Diagnosis

Diagnosis integrates with monitor mode — when a process becomes hung, diagnosis triggers automatically:

```bash
./hung_detect -m --sample                 # Auto-sample on hung
sudo ./hung_detect -m --full              # Full auto-diagnosis
sudo ./hung_detect -m --full --spindump-duration 5 --spindump-system-duration 5  # Full auto-diagnosis with 5s spindumps
./hung_detect -m --sample --json | jq .   # Stream diagnosis events as NDJSON
```

### Trigger Logic (Monitor Mode)

- Diagnosis is triggered on transition to hung (`responding -> not responding`), not on every poll tick.
- On monitor startup, processes that are already hung trigger one diagnosis round immediately.
- If a process stays hung, it will not retrigger until it becomes responsive and hangs again.
- Per-process diagnosis (`sample` / per-PID `spindump`) is deduplicated while a PID is already being diagnosed.
- With `--full`, each hung trigger also starts one system-wide `spindump`; this can still run even when per-PID work is deduplicated.

Examples:

- `responding -> not responding`:
  - `--sample`: 1 `sample`
  - `--sample --spindump`: 1 `sample` + 1 per-PID `spindump`
  - `--full`: 1 `sample` + 1 per-PID `spindump` + 1 system-wide `spindump`
- `responding -> not responding -> responding -> not responding`:
  - usually two diagnosis rounds
  - if the second hang happens before the first round for the same PID finishes, per-PID tools may be skipped by dedup

## 📄 License

Apache License 2.0. See `LICENSE`.
