# hung_diagnosis 🩺

[🇺🇸 English](./HUNG_DIAGNOSIS.md) | [🇨🇳 简体中文](./HUNG_DIAGNOSIS.zh-CN.md)

[`hung_detect`](./README.zh-CN.md) 的配套诊断工具。检测到未响应进程后，自动并行采集 `sample` 和 `spindump` 数据，用于定位根因。

## 工作流程

1. 调用 `hung_detect --json` 发现未响应进程。
2. 按选定级别并行采集诊断数据。
3. 保存输出文件并汇报结果和耗时。

## 三级诊断

| 级别 | 参数 | 工具 | 需要 sudo |
|---|---|---|---|
| 1（默认） | *（无）* | 每进程 `sample` | 否 |
| 2 | `--spindump` | + 每进程 `spindump` | 是 |
| 3 | `--full` | + 全量 `spindump` | 是 |

### 各工具说明

- **`sample`（每进程）** — CPU 调用栈采样，看主线程卡在哪里。快速轻量，输出约 160KB。
- **`spindump`（每进程）** — 线程阻塞分析，包含 hung 时长信息（如 "Unresponsive for 68972 seconds before sampling"）。包含关联进程，输出约 19MB。
- **`spindump`（全量）** — 全系统快照，包含所有进程和跨进程依赖关系。更大更慢，输出约 37MB。

## 使用示例

```bash
# 级别 1：仅 sample
./hung_diagnosis

# 级别 2：+ 每进程 spindump
sudo ./hung_diagnosis --spindump

# 级别 3：+ 全量 spindump
sudo ./hung_diagnosis --full

# 自定义采样时长（默认 3 秒）
sudo ./hung_diagnosis --full --duration 5

# 循环模式：每 10 秒扫描一次
sudo ./hung_diagnosis --spindump --loop 10

# 自定义输出目录
./hung_diagnosis --outdir /tmp/diag
```

## CLI 参数

| 参数 | 说明 |
|---|---|
| `--spindump` | 增加每进程 spindump（级别 2） |
| `--full` | 增加每进程 + 全量 spindump（级别 3） |
| `--duration SEC` | 采样时长，单位秒（默认：3） |
| `--outdir DIR` | 输出目录（默认：`./hung_diagnosis_output`） |
| `--loop SEC` | 循环扫描间隔秒数；不指定则单次扫描 |
| `--max N` | 最大并行任务数（默认：8） |

## 输出文件

所有文件保存在 `hung_diagnosis_output/`（或 `--outdir`），以时间戳为前缀：

```
hung_diagnosis_output/
├── 20260214_014637_AlDente_913.sample.txt       # 每进程 sample
├── 20260214_014637_AlDente_913.spindump.txt     # 每进程 spindump (--spindump/--full)
└── 20260214_014637_system.spindump.txt          # 全量 spindump (仅 --full)
```

- `*.sample.txt` — 可通过 Instruments 的 File > Open 导入分析。
- `*.spindump.txt` — 纯文本，用任意文本编辑器打开。

## 输出示例

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

## 并行执行

所有诊断任务并发执行。以 `--full` + 3 个 hung 进程为例：

```
ThreadPoolExecutor
├── sample    PID=913  AlDente
├── sample    PID=512  Finder
├── sample    PID=2048 Safari
├── spindump  PID=913  AlDente
├── spindump  PID=512  Finder
├── spindump  PID=2048 Safari
└── spindump  全量
```

总耗时 = 最慢的单个任务，不会叠加。

## 退出码

- `0` — 所有进程正常响应（无需诊断）。
- `1` — 发现 hung 进程，已采集诊断数据。
- `2` — 错误（找不到 hung_detect 等）。

## 环境要求

- `hung_detect` 二进制文件在同一目录（先执行 `make build`）。
- `sample` 和 `spindump`（macOS 自带）。
- Python 3（macOS 自带）。
- `--spindump` 和 `--full` 需要 `sudo`（spindump 需要 root 权限）。

## 备注

- 使用 `sudo` 运行时，输出文件会自动 `chown` 回原始用户。
- 支持 `NO_COLOR` 环境变量和 TTY 检测，自动控制彩色输出。
- 错误信息显示为红色，警告信息显示为黄色。

## 许可证

Apache License 2.0，见 `LICENSE`。
