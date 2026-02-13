# hung_detect 🔍

[🇺🇸 English](./README.md) | [🇨🇳 简体中文](./README.zh-CN.md)

`hung_detect` 是一个用 Swift 实现的 macOS GUI 进程“未响应”检测工具。
它使用与活动监视器一致的私有 Window Server 信号（`CGSEventIsAppUnresponsive`）。

## ✨ 功能

- 用活动监视器风格的信号判断 GUI 应用是否未响应。
- 支持通用二进制构建（`arm64` + `x86_64`）。
- 可配置最小系统版本，默认 `12.0`。
- 支持终端表格输出和 JSON 输出。
- 输出进程元信息：PID、父 PID、用户、Bundle ID、架构、沙盒状态、防睡眠状态、运行时长、可执行文件路径。
- 可选显示 SHA-256。

## 🧰 环境要求

- macOS
- Xcode 命令行工具（`swiftc`、`xcrun`、`lipo`）

## 🏗️ 构建

默认构建（`MIN_MACOS=12.0`）：

```bash
make build
```

指定最小系统版本：

```bash
make build MIN_MACOS=12.0
```

检查产物架构和 `minos`：

```bash
make check
```

兼容脚本入口（内部会转调 Makefile）：

```bash
./build_hung_detect.sh 12.0
```

## 🍺 Homebrew Tap 安装

Homebrew 安装会直接使用 `dist/` 中的预编译二进制包，不在用户机器上编译。

本地把当前仓库作为 tap：

```bash
brew tap fjh658/hung-detect /path/to/hung_detect
brew install fjh658/hung-detect/hung-detect
```

从 GitHub tap 安装：

```bash
brew tap fjh658/hung-detect https://github.com/fjh658/hung_detect.git
brew install fjh658/hung-detect/hung-detect
```

发布前更新预编译包：

```bash
make package VERSION=0.1.0 MIN_MACOS=12.0
```

## 🚀 使用示例

```bash
./hung_detect
./hung_detect --all
./hung_detect --json
./hung_detect --name Chrome
./hung_detect --pid 913
```

## 🖼️ 截图

### 表格输出

![hung_detect table output](images/hung_detect.png)

### JSON 输出

![hung_detect json output](images/hung_detect_json.png)

## ⚙️ CLI 参数

- `--all`, `-a`：显示所有匹配 GUI 进程（默认仅显示未响应进程）。
- `--sha`：在表格输出中显示 SHA-256 列。
- `--pid <PID>`：按 PID 过滤（可重复）。
- `--name <NAME>`：按应用名或 bundle ID 过滤（可重复）。
- `--json`：输出 JSON（始终包含 `sha256` 字段）。
- `--no-color`：关闭 ANSI 颜色。
- `-h`, `--help`：显示帮助。

## 📌 退出码

- `0`：所有扫描/匹配进程都在响应。
- `1`：至少有一个进程未响应。
- `2`：参数错误或运行时错误。

## 🔒 私有 API 兼容说明

本工具有意使用私有 API。不同 macOS 版本中，符号可能发生重导出或命名变化。
当前实现已做回退解析：

- `CGSMainConnectionID`、`CGSEventIsAppUnresponsive`
  - 同时尝试 `SkyLight` 与 `CoreGraphics`
  - 同时尝试无前缀和 `_` 前缀符号名
- `LSASNCreateWithPid`、`LSASNExtractHighAndLowParts`
  - 同时尝试 `CoreServices` 与 `LaunchServices`
  - 同时尝试 `_`、无前缀、`__` 三种符号名

如果必须符号都无法解析，程序会以退出码 `2` 结束。

## ⚡ 性能说明

- SHA-256 改为延迟计算，只对最终输出的行计算。
- `--json --all` 会比默认模式慢，因为需要输出并哈希所有匹配进程。

## 🩺 hung_diagnosis

配套诊断脚本，自动对 `hung_detect` 检测到的未响应进程采集 `sample` 和 `spindump` 数据。详见 [HUNG_DIAGNOSIS.zh-CN.md](./HUNG_DIAGNOSIS.zh-CN.md)。

## 📄 许可证

Apache License 2.0，见 `LICENSE`。
