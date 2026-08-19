# DeepSeek Harness GUI

<p align="center">
  <img src="docs/app-icon.png" width="128" height="128" alt="DeepSeek Harness GUI icon">
</p>

[![CI](https://github.com/liangqianxing/deepseek-harness-gui/actions/workflows/ci.yml/badge.svg)](https://github.com/liangqianxing/deepseek-harness-gui/actions/workflows/ci.yml)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111827)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-0f766e.svg)](LICENSE)

一个轻量的 macOS 原生外壳，将 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 嵌入 `WKWebView`，并负责本地服务的启动、复用、状态监控和退出清理。

> 本项目是社区维护的非官方 GUI，不隶属于 DeepSeek。DeepSeek Harness 的名称和上游代码归其各自权利人所有。

## 特性

- 启动时检查本机 dsh，已有实例直接复用，不重复占用端口
- 默认使用 `localhost:3080`，端口被其他程序占用时让 dsh 自动分配可用端口
- 原生工具栏提供启动、停止、重启、刷新、外部浏览器和日志
- 只停止 GUI 自己启动的 dsh，不终止由终端或其他应用管理的实例
- 内嵌固定版本的 Node.js 与 dsh runtime，Finder 启动不依赖终端 `PATH`
- 使用 dsh 自己的 `~/.dsh/settings.yaml` 和 `~/.dsh/.credentials.yaml`
- 不读取、复制或写入模型 API key；日志也不会打印凭证内容
- WebView 只允许当前本地 dsh 页面，普通外链交给系统浏览器

## 环境要求

- macOS 13 或更高版本
- Xcode Command Line Tools
- 可访问 nodejs.org 和 npm registry（首次构建需要下载固定版本的 Node.js 与 dsh runtime）

## 快速开始

```bash
git clone https://github.com/liangqianxing/deepseek-harness-gui.git
cd deepseek-harness-gui
./build.sh
open "$HOME/Applications/DeepSeek Harness GUI.app"
```

`build.sh` 会：

1. 编译 Swift/AppKit + WebKit 应用；
2. 下载并校验固定版本的官方 Node.js；
3. 根据 `Runtime/package-lock.json` 安装固定版本的 dsh runtime；
4. 将 Node.js 和 runtime 放进 app bundle；
5. 对 bundle 做本地 ad-hoc 签名并验证；
6. 将应用安装到 `~/Applications/DeepSeek Harness GUI.app`。

完整构建会产生约 400 MB 的 app bundle。构建产物位于 `dist/`，不会提交到 Git。

只构建到 `dist/`、不复制到 `~/Applications`：

```bash
INSTALL_LOCAL=0 ./build.sh
```

## dsh 配置

GUI 不提供凭证录入界面，也不会改变 dsh 的配置格式。请先按照 dsh 的文档完成本机配置，例如：

```yaml
# ~/.dsh/settings.yaml
llm-deepseek:
  apiKeyEnv: PROVIDER_API_KEY
  baseURL: https://example.invalid/v1
  models:
    - id: example-model
      name: Example Model
      contextWindow: 128000
agent-default-model:
  provider: deepseek-official
  model: example-model
```

凭证文件应由 dsh 管理并保持合适的权限；不要把真实 key、token 或 `.credentials.yaml` 提交到仓库。

## 开发与验证

运行脚本检查、Info.plist 校验和 Swift release 编译：

```bash
./scripts/check.sh
```

开发端口可通过环境变量覆盖：

```bash
DSH_GUI_PORT=3098 \
  "$HOME/Applications/DeepSeek Harness GUI.app/Contents/MacOS/DeepSeekHarnessGUI"
```

GUI 日志写入：

```text
~/Library/Logs/DeepSeek Harness GUI.log
```

## 项目结构

```text
Sources/main.swift             AppKit 窗口、WKWebView 和服务状态机
Resources/start-dsh.sh         dsh 启动器
Resources/Info.plist           macOS bundle 元数据
Runtime/package.json           runtime 版本声明
Runtime/package-lock.json      可复现依赖锁定
build.sh                       编译、打包、签名和安装
scripts/check.sh               本地/CI 编译检查
```

## 设计边界

- GUI 只连接本机 `localhost` / `127.0.0.1`，不做代理或远程转发。
- 外部 dsh 实例只读监控和复用；停止、重启按钮仅对 GUI 自己拥有的进程生效。
- 应用使用本地 ad-hoc 签名，适合开发和个人使用；分发给其他用户前应使用自己的 Apple Developer 签名和公证流程。
- DeepSeek Harness 及其依赖遵循各自上游许可证；本项目代码采用 MIT License。

## 贡献

请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请参阅 [SECURITY.md](SECURITY.md)。

## License

[MIT](LICENSE)
