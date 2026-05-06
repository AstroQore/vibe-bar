# Vibe Bar

**Read this in:** [English](README.md) · **中文**

Vibe Bar 是一款面向 Codex 和 Claude Code 用户的原生 macOS 菜单栏应用，
把订阅配额、用量节奏、本地 Token 成本和服务状态收拢到一个安静的桌面入口。
它专为同时使用 OpenAI/Codex 与 Anthropic/Claude Code 的开发者设计，
让关键数据不再需要打开多个面板就能一眼看到。

<p align="center">
  <img src="Resources/README/overview-dashboard.png" alt="Vibe Bar overview dashboard" width="760">
</p>

> ### 在使用 AI 编码 Agent？
>
> 仓库内为 AI Agent（Claude Code、Codex、Cursor、Aider 等）准备了两份
> **零背景**说明文档。把其中任意一份交给你的 Agent，它就能自行接管：
>
> - **[AGENT-DEPLOY.md](AGENT-DEPLOY.md)** —— 拉取代码、构建、打包、冒烟测试，
>   并在征得你同意后安装到 `/Applications`。
> - **[AGENT-PR.md](AGENT-PR.md)** —— 切分支、本地校验，并按本仓库约定提交
>   Pull Request。
>
> 两份文档都设计为自包含 —— 即便 Agent 对项目毫无背景，也能逐步跟着完成。

## 功能亮点

- 菜单栏配额指示器，分别覆盖 OpenAI/Codex 与 Anthropic/Claude Code。
- 总览仪表盘：配额节奏、状态、成本历史、Token 累计。
- 服务商详情页：订阅利用率、模型排行、热力图、小时燃烧速率、实时服务状态。
- 迷你浮窗：常规与紧凑两种布局。
- 本地优先的成本统计，全部来自 CLI 会话日志。
- 隐私控制：可设置保留期限、清除衍生成本数据，或直接关闭成本历史持久化。

## 适用人群

Vibe Bar 关注本仓库唯一在意的两类编码 Agent 工作流：

- **Codex/OpenAI 用量**：订阅时间窗、重置时间、服务状态，以及本地 Codex 会话
  的成本/Token 历史。
- **Claude Code/Anthropic 用量**：配额/Routine 预算可视化、服务状态，以及
  本地 Claude Code 会话的成本/Token 历史。
- **混合日常**：菜单栏与迷你窗的紧凑视图，让你不用切换厂商面板就能对比节奏、
  剩余配额和近期开销。

## 截图

### 服务商详情

<p align="center">
  <img src="Resources/README/openai-detail.png" alt="OpenAI detail page" width="420">
  <img src="Resources/README/claude-detail.png" alt="Claude detail page" width="420">
</p>

### 迷你窗口

<p align="center">
  <img src="Resources/README/mini-window-regular.png" alt="Regular mini window" width="520">
</p>

<p align="center">
  <img src="Resources/README/mini-window-compact.png" alt="Compact mini window" width="180">
</p>

### 设置

<p align="center">
  <img src="Resources/README/settings-mini-window.png" alt="Mini window settings" width="420">
</p>

## 它能展示什么

Vibe Bar 把实时配额和本地用量分析合并到同一处：

- 当前配额时间窗、重置时间、剩余百分比和节奏标记。
- 今日、近 7 天、近 30 天和总计的成本数字。
- Top 模型用量与模型排名。
- 每日成本历史，以及当日的小时燃烧速率。
- 类似 GitHub 贡献图的年度用量热力图。
- OpenAI 与 Anthropic 服务状态。

菜单栏图标也支持右键上下文菜单，包含完整用量行、服务商状态、刷新、迷你窗、
设置和退出操作。

## 隐私与本地数据

运行时状态保存在当前用户的家目录下：

```text
~/.vibebar/
├── settings.json
├── quotas/
├── cost_snapshots/
├── scan_cache/
├── service_status.json
└── cost_history.json
```

Vibe Bar 会读取本地 CLI 凭据和 Claude/Codex 会话 JSONL 日志，但**不会**写入
这些 CLI 凭据或会话文件。衍生出的成本和 Token 历史只保留在你的 Mac 上，
除非你自己选择导出或公开。

Claude 网页 Cookie 会被收窄到必要的 `sessionKey`，统一存放在 Keychain 里；
解析得到的 Claude 组织 ID 也存在 Keychain。`~/.vibebar/cookies/` 下的旧版
明文 Cookie 文件会在首次读取时迁移到 Keychain 并被清理。

成本历史保留期限可在「设置」中配置，默认是「永久」。隐私模式会清空本地成本
历史、快照和扫描缓存，并在启用期间不再把成本数据写入磁盘。「Cost Data」设置
还提供手动「Clear Cost Data」操作。

## 系统要求

- macOS 26 或更高版本。
- Xcode 26 / Swift 6.2 工具链。
- 想看实时配额，需要本地 OpenAI/Codex 和/或 Claude 凭据。
- 想看成本和 Token 历史，需要本地 CLI 会话日志。

## 从源码构建

```bash
swift test
./Scripts/build_app.sh
open ".build/Vibe Bar.app"
```

SwiftPM 的可执行产物名是 `VibeBar`。打包脚本会构建可执行文件、生成
`.build/Vibe Bar.app`、复制 App 图标和 Info.plist，并对 Bundle 做 ad-hoc
签名以便本地运行。

Debug 构建：

```bash
./Scripts/build_app.sh debug
```

Release 构建：

```bash
./Scripts/build_app.sh release
```

## 开发说明

- `Package.swift` 定义了 `VibeBar` 可执行目标和 `VibeBarCore` 库。
- `Sources/VibeBarApp` 存放 SwiftUI/AppKit 菜单栏应用。
- `Sources/VibeBarCore` 存放解析器、存储、隐私辅助器和用量计算逻辑。
- `Scripts/build_app.sh` 负责生成并 ad-hoc 签名 App Bundle。
- 打包时会把 `Resources/AppIcon.icns` 复制进 Bundle。
- `swift test` 覆盖解析器、设置、计费、隐私持久化以及通用工具。

## 项目状态

Vibe Bar 处于早期公开发布阶段。围绕厂商 API、模型计费、打包流程和 macOS 设计
细节会有较快的迭代节奏。

## 许可证

Vibe Bar 采用 GNU Affero General Public License v3.0 only（AGPL-3.0-only）
许可。完整许可证文本见 [LICENSE](LICENSE)。
