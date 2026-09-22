# CodexSpeed

**简体中文** | [English](README.en.md)

一个轻量的 macOS 悬浮窗，用于查看 Codex 任务速度、用量和额度。
只读本地日志，无需 API Key，不上传对话内容。非 OpenAI 官方项目。

## 功能

- 显示输出速度（tok/s）、任务状态、耗时、Token 用量和上下文估算。
- 自动跟随最近活跃的 Codex Desktop 主任务，也可手动锁定任务。
- 完整 / 极简悬浮窗，支持收至菜单栏、拖动和记住位置。
- 中英文界面，浅色 / 深色 / 跟随系统，以及玻璃、实色、透明背景。
- 展示日志中的额度和重置时间；可配合 ccusage 估算 API 等价容量。

## 构建与运行

运行需要 macOS 13+；源码构建需要带 macOS 26+ SDK 的 Swift 工具链
（使用了 Liquid Glass API，旧系统运行时自动回退）。无第三方 Swift 包依赖。

```sh
git clone https://github.com/XYoungSky/CodexSpeed.git
cd CodexSpeed
./scripts/build-app.sh
open dist/CodexSpeed.app
```

构建产物为当前 Mac 架构的 `dist/CodexSpeed.app`，使用本地临时签名，未经公证。
图标由构建脚本自动生成。

默认读取 `~/.codex`。路径不同时，在设置中选择包含 `sessions` 的 Codex 主目录。
通过顶部按钮切换极简模式、收至菜单栏或打开设置；点击菜单栏图标可恢复悬浮窗。

## 数据说明

- **速度**：运行时为近期日志增量估算；完成后为整轮输出 Token ÷ 耗时，包含工具执行和等待。
- **额度**：来自日志快照，可能延迟；不是实时服务器查询。缺失指标显示 `—`。
- **读取范围**：最近 14 个 UTC 自然日内修改过的日志，包含活动和归档目录；启动后增量读取。
- **费用估算（可选）**：仅适配 `ccusage 20.0.20`，在设置中指定其可执行文件，默认路径为 `/opt/homebrew/bin/ccusage`。未安装时仍可查看速度和日志额度。
- **校准条件**：至少 3 个有效快照、10 分钟跨度、5 个百分点消耗；重置或价格变化后重新采样。

金额是 API 等价容量估算，**不是订阅余额或账单**。跨设备使用、日志缺失、模型价格和消耗权重都会影响结果。
ccusage 以离线模式运行；价格快照位于 [Pricing.swift](Sources/CodexSpeedCore/Pricing.swift)，不会自动更新。
未知模型及不支持的长上下文计价会暂停校准。日志格式变化也可能影响兼容性。

设置保存于 UserDefaults；校准记录位于
`~/Library/Application Support/CodexSpeed/calibration.json`，不含对话正文。
应用没有 App Sandbox，请仅配置可信的 ccusage 可执行文件。

## 开发

```sh
./scripts/test.sh
```

测试使用独立的 `CoreChecks` 可执行目标；ccusage 集成检查在默认路径未安装 ccusage 时跳过。

```text
Sources/CodexSpeed/       窗口、菜单栏与设置
Sources/CodexSpeedCore/   日志解析、速度统计与额度校准
Tests/                   核心检查
scripts/                 测试、构建与图标生成
Assets/                  图标矢量稿
```

## 许可证

[MIT](LICENSE)
