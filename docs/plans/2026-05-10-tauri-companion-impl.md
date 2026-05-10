# Tauri Companion App — 阶段实施计划

> **关联设计**: [2026-05-10-tauri-companion-design.md](../designs/2026-05-10-tauri-companion-design.md)
> **独立 track**: 不跟 ai-agents-kit 主干 v3.x.y tag 链;用 `companion-phase-N-*` 命名
> **批准 gate**: Phase 0 完成后等 Lane 批准方向再启动 Phase 1

---

## Phase 0 — 设计 + 骨架(本次)

**已完成**:
- [x] 设计文档 `docs/designs/2026-05-10-tauri-companion-design.md`
- [x] 实施计划 `docs/plans/2026-05-10-tauri-companion-impl.md`(本文)
- [x] 目录骨架 `companion/README.md` + `companion/.gitignore`

**未做**:
- [ ] Tauri 项目初始化(`npm create tauri-app`)— 等 Phase 1 启动
- [ ] 任何 Rust / TS 代码

**commit**: `companion-phase-0-design` 标签

---

## Phase 1 — MVP (单项目 watcher + 托盘 + 浮动通知)

**目标**: 跑出第一个能用的 .exe。choseStock 单项目监控,任务完成弹浮动卡片含 [去审查] 按钮。

### 1.1 工程初始化

- [ ] 进 `companion/`:
  ```bash
  cd C:/Users/mi/ai-agents-kit/companion
  npm create tauri-app@latest -- --template react-ts --manager pnpm --name ai-agents-companion
  ```
- [ ] 运行 `pnpm tauri dev` 验证 hello-world 能跑
- [ ] commit: `companion-phase-1-init`

**验证**:
- `pnpm tauri dev` 弹一个 hello world 窗口
- 关闭后 `pnpm tauri build` 能产出 .exe(在 `src-tauri/target/release/`)

### 1.2 Rust 后端 — 文件 watcher

文件: `companion/src-tauri/src/watcher.rs`

- [ ] 加 deps: `notify = "6"`, `serde = "1"`, `serde_json = "1"`, `tokio = { version = "1", features = ["full"] }`
- [ ] 写 `ProjectWatcher` struct:
  - 字段: `project_path: PathBuf`, `event_tx: mpsc::Sender<...>`
  - `start()` 跑 fsnotify 监听 `<path>/.aiagents/state/current.json`
  - 文件变化 → 解析 JSON → 计算 state diff → 推 event 到 channel
- [ ] 单元测试: tempdir + 写假 state.json + 期望 watcher 推 event

**接口**:
```rust
pub enum WatcherEvent {
    StateChanged { agent: String, from: String, to: String },
    EventAppended { line: String },
    WatcherStale { reason: String },
}
```

### 1.3 Rust 后端 — Tauri command 白名单

文件: `companion/src-tauri/src/commands.rs`

- [ ] `dispatch(project_path, agent, provider)` — spawn `bash agentctl.sh dispatch ...`
- [ ] `release_without_verify(project_path, agent, reason)`
- [ ] `retry_other_provider(project_path, agent)`
- [ ] `open_in_claude_code(project_path)` — Win 上 `start "" "claude-code://open?path=..."` 或调 `code` CLI
- [ ] 单元测试: 白名单拦截非法 subcommand

### 1.4 前端 — 浮动卡片组件

文件: `companion/src/components/FloatingCard.tsx`

- [ ] React 组件,props: `project, agent, status, message, actions[]`
- [ ] 不可关闭(没 [×],只能点动作或显式关)
- [ ] 配色按 status 区分:
  - done-awaiting-review / ready-for-human → 绿
  - failed → 红
  - timeout → 黄
- [ ] 动作按钮 onClick 调 `invoke('dispatch', ...)` 之类的 Tauri command

### 1.5 前端 — 浮动窗口管理器

文件: `companion/src/components/FloatingManager.tsx`

- [ ] 用 Tauri WebView 二级窗口(`tauri::WebviewWindow`)
- [ ] 全局监听 `WatcherEvent::StateChanged` → 决定弹哪个卡片
- [ ] 多个卡片堆叠(右下角竖向排列)

### 1.6 系统托盘

文件: `companion/src-tauri/src/tray.rs`

- [ ] Tauri v2 自带 tray API
- [ ] 默认图标(灰色),状态变化时换图标(蓝/绿/黄/红)
- [ ] 右键菜单: 显示主窗口 / 退出

### 1.7 端到端冒烟

- [ ] 跑 `pnpm tauri dev`
- [ ] 在 choseStock 派一个测试任务: `bash D:/dev/ai/workspace/choseStock/.aiagents/bin/agentctl.sh dispatch backend`
- [ ] 桌宠应该:
  1. 托盘图标变蓝(running)
  2. 任务完成 → 图标变绿,弹浮动卡片
  3. 卡片含 [去审查] 按钮,点击打开 Claude Code

**验证**:
- [ ] 浮动卡片不会自动消失(放置 5 分钟仍在)
- [ ] [去审查] 能正确开 Claude Code 到 choseStock 项目
- [ ] 关闭桌宠不影响 v3.1 toast 兜底(仍能弹气泡)

**commit**: `companion-phase-1-mvp`

---

## Phase 2 — 多项目注册 + 主窗口 + 设置

### 2.1 设置文件

- [ ] `~/.config/ai-agents-companion/settings.toml`(Win 上 `%APPDATA%/ai-agents-companion/settings.toml`)
- [ ] `serde + toml` 解析
- [ ] 启动时载入,改动时保存 + 通知 watcher 重启

### 2.2 项目注册 UI

- [ ] 主窗口左侧项目列表
- [ ] [+ 添加] 按钮 → 文件选择器选项目根目录
- [ ] 校验: 必须含 `.aiagents/bin/agentctl.sh`,否则报错
- [ ] 增删改 enable/disable

### 2.3 主窗口右侧详情面板

- [ ] 状态 panel(backend / frontend state + provider + worker pid + heartbeat)
- [ ] Recent events 流(从 events.jsonl 读末尾 20 条)
- [ ] Toolbar: [Dispatch BE] [Dispatch FE] [Status] [Open in Code]

### 2.4 设置面板

- [ ] 浮动卡片位置(下拉: 右下/右上/左下/左上)
- [ ] 通知开关(全局/按 status)
- [ ] 开机自启(Tauri auto-launch plugin)

**commit**: `companion-phase-2-multi-project`

---

## Phase 3 — 完整交互动作

### 3.1 浮动卡片所有按钮可用

- [ ] done-awaiting-review: [去审查](opens Claude Code)/ [详情](展开 events)
- [ ] ready-for-human: [收下] = release-without-verify / [打回] = 写 04 修复单(打开编辑器)/ [推迟] = 隐藏
- [ ] failed: [retry-other-provider] / [bugfix] = 派 04 修复单
- [ ] timeout: [看诊断] = 显示 stop-notify 注入的诊断 / [retry-other-provider]

### 3.2 命令调用 + UI 反馈

- [ ] 调命令时按钮变 loading 状态
- [ ] 命令完成 → toast 反馈 "已派单 / 已 release / ..."
- [ ] 命令失败 → 错误浮窗

### 3.3 stale watcher 自愈

- [ ] heartbeat 超过 30s → 桌宠托盘图标加感叹号 + 浮动通知 "watcher 失联"
- [ ] [重启 watcher] 按钮直接调 `kill old + agentctl.sh watch <agent>`

**commit**: `companion-phase-3-actions`

---

## Phase 4 — 桌宠角色(可选)

> **决策点**: Phase 3 完成后 Lane 决定是否做 Phase 4。核心功能 Phase 1-3 已经完整。

### 4.1 透明浮动角色窗口

- [ ] Tauri 创建透明无边框窗口
- [ ] 默认右下角偏左 200px
- [ ] 鼠标可拖拽

### 4.2 状态动画

- [ ] sprite sheet 或 GIF 序列(每 state 一组帧)
- [ ] state 变化 → 切换动画
- [ ] 鼠标悬浮显示项目名 + 状态文字气泡

### 4.3 美术资源

- [ ] 自做 / 外包 / 用开源资源(如 Live2D 模型 / Pixel art sprite)
- [ ] 多套皮肤(设置面板可换)

**commit**: `companion-phase-4-pet`

---

## 后续迭代(暂不规划)

- macOS / Linux 跨平台
- 远程通知(可选 webhook 到 Slack/Discord)
- AI 助手集成: 桌宠对话气泡接 Claude API 给建议
- Spotify-style 任务时间线(Gantt)

---

## 风险点 & 决策记录

| 决策 | 选择 | 理由 | 日期 |
|---|---|---|---|
| 框架 | Tauri | 体积/性能/类型安全 | 2026-05-10 |
| 前端 | React + Vite + TS | 与 stock-fe 风格一致,Lane 熟 | 2026-05-10 |
| 包管理 | pnpm | npm 慢且 node_modules 大 | 2026-05-10 |
| 状态读取 | fsnotify + poll 兜底 | 跨平台 + 网络盘兜底 | 2026-05-10 |
| 命令调用 | spawn `bash agentctl.sh` | 与主干约定一致,无 IPC 协议设计成本 | 2026-05-10 |
| 安装方式 | 独立 .exe + 不打包进 install.sh | 主干零依赖,桌宠可选 | 2026-05-10 |
| (待定) | macOS/Linux 是否一期支持 | 等 Lane 拍 | — |
| (待定) | Phase 4 桌宠美术风格 | 等 Lane 拍 | — |
