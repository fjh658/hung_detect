# hung_diagnosis 🩺

[🇺🇸 English](./HUNG_DIAGNOSIS.md) | [🇨🇳 简体中文](./HUNG_DIAGNOSIS.zh-CN.md)

A companion diagnostic tool for [`hung_detect`](./README.md). When not-responding processes are found, it automatically collects `sample` and `spindump` data in parallel for root-cause analysis.

## How It Works

1. Calls `hung_detect --json` to find not-responding processes.
2. Collects diagnostic data at the selected level (all tasks run in parallel).
3. Saves output files and reports results with timing.

## Three Diagnosis Levels

| Level | Flag | Tools | Requires sudo |
|---|---|---|---|
| 1 (default) | *(none)* | per-process `sample` | No |
| 2 | `--spindump` | + per-process `spindump` | Yes |
| 3 | `--full` | + system-wide `spindump` | Yes |

### What each tool provides

- **`sample` (per-process)** — CPU call-stack profiling. Shows where the main thread is stuck. Fast, lightweight (~160KB output).
- **`spindump` (per-process)** — Thread blocking analysis with hung duration info (e.g. "Unresponsive for 68972 seconds before sampling"). Includes related processes (~19MB output).
- **`spindump` (system-wide)** — Full system snapshot with all processes and cross-process dependencies. Larger and slower (~37MB output).

## Usage

```bash
# Level 1: quick sample only
./hung_diagnosis

# Level 2: + per-process spindump
sudo ./hung_diagnosis --spindump

# Level 3: + system-wide spindump
sudo ./hung_diagnosis --full

# Custom duration (default 3 seconds)
sudo ./hung_diagnosis --full --duration 5

# Loop mode: scan every 10 seconds
sudo ./hung_diagnosis --spindump --loop 10

# Custom output directory
./hung_diagnosis --outdir /tmp/diag
```

## CLI Options

| Option | Description |
|---|---|
| `--spindump` | Add per-process spindump (level 2) |
| `--full` | Add per-process + system-wide spindump (level 3) |
| `--duration SEC` | Sampling duration in seconds (default: 3) |
| `--outdir DIR` | Output directory (default: `./hung_diagnosis_output`) |
| `--loop SEC` | Loop scan interval; omit for single scan |
| `--max N` | Max parallel tasks (default: 8) |

## Output Files

All files are saved to `hung_diagnosis_output/` (or `--outdir`) with timestamp prefix:

```
hung_diagnosis_output/
├── 20260214_014637_AlDente_913.sample.txt       # sample per-process
├── 20260214_014637_AlDente_913.spindump.txt     # spindump per-process (--spindump/--full)
└── 20260214_014637_system.spindump.txt          # system-wide spindump (--full only)
```

- `*.sample.txt` — Can be imported into Instruments via File > Open.
- `*.spindump.txt` — Plain text, open with any text editor.

## Example Output

```
[2026-02-14 01:46:37] hung_diagnosis - not-responding process diagnostic tool
[2026-02-14 01:46:37] duration: 3s | tools: sample + spindump + system-wide | output: ./hung_diagnosis_output

[2026-02-14 01:46:37] found 1 not-responding process(es):
[2026-02-14 01:46:37]   PID=913  AlDente
[2026-02-14 01:46:37] starting diagnosis (sample + spindump per-process + system-wide spindump, 3s)...
[2026-02-14 01:46:40]   AlDente (PID 913):
[2026-02-14 01:46:40]     ├─ sample    ...sample.txt (161281 bytes, 3.3s)
[2026-02-14 01:46:48]     └─ spindump  ...spindump.txt (19553212 bytes, 10.9s)
[2026-02-14 01:47:00]   system-wide spindump: ...system.spindump.txt (35067287 bytes, 22.1s)
[2026-02-14 01:47:00] diagnosis complete in 22.1s, output: ./hung_diagnosis_output
```

## Parallel Execution

All diagnostic tasks run concurrently. With 3 hung processes at `--full`:

```
ThreadPoolExecutor
├── sample    PID=913  AlDente
├── sample    PID=512  Finder
├── sample    PID=2048 Safari
├── spindump  PID=913  AlDente
├── spindump  PID=512  Finder
├── spindump  PID=2048 Safari
└── spindump  system-wide
```

Total wall time = the slowest single task, not the sum.

## Exit Codes

- `0` — All processes responding (nothing to diagnose).
- `1` — Hung processes found, diagnostics collected.
- `2` — Error (hung_detect not found, etc.).

## Requirements

- `hung_detect` binary in the same directory (run `make build` first).
- `sample` and `spindump` (macOS built-in).
- Python 3 (macOS built-in).
- `sudo` for `--spindump` and `--full` (spindump requires root).

## Notes

- When running with `sudo`, output files are automatically `chown`'d back to the original user.
- Respects `NO_COLOR` environment variable and TTY detection for colored output.
- Error messages are shown in red, warnings in yellow.

## License

Apache License 2.0. See `LICENSE`.
