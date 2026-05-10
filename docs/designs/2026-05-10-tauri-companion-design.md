# Tauri Companion App — 设计方案

> **状态**: Phase 0 设计 — 待 Lane 审阅
> **作者**: Claude (Opus 4.7)
> **日期**: 2026-05-10
> **关联**: v3.1 桌面通知层（NotifyIcon Toast）的进化版
> **独立 track**: 不动 ai-agents-kit 主干（`templates/` / `install.sh` 一字不改）

## 1 · Goal & Non-Goals

### Goal — 解决什么痛点

当前 v3.1 NotifyIcon Toast 的局限:

| 痛点 | 现状（v3.1） | 目标（companion） |
|---|---|---|
| 通知 8 秒消失 | 一闪而过,Lane 离开座位回来就丢 | **浮动卡片**长驻直到 Lane 关闭 |
| 不能交互 | 只是文字提示 | 含按钮: [去审查] [详情] [release-without-verify] [retry-other-provider] [忽略] |
| 不知道任务历史 | 看 events.jsonl 才知道 | 主窗口列出 events 流 + 当前 active 任务 |
| 单项目盲区 | 只能监控当前 cwd 项目 | **多项目同时监控**(choseStock + 其他) |
| 无情感反馈 | 纯文字 | 桌宠角色(Phase 4 可选): 状态映射表情/动画 |

### Non-Goals — 明确不做的事

- ❌ **不重写 ai-agents-kit 主干** — `templates/` / `install.sh` / Bash 工作流一字不动
- ❌ **不替代 Claude Code** — Claude Code 仍是主操作面;companion 只是通知 + 快捷动作
- ❌ **不持久化业务数据** — 不存任务历史超出 `.aiagents/state/events.jsonl` 之外(项目自治)
- ❌ **不与 provider 直接对话** — 不调 codex / claude CLI;所有写操作走 `agentctl.sh`
- ❌ **不做远程通知** — 桌宠是本机 desktop app,不是 webhook / Slack bot

---

## 2 · 架构概览

```
┌─────────────────────────────────────────────────┐
│   ai-agents-kit 现有主干 (Bash/PowerShell)      │
│   watch-agent.sh / agent-runner.sh /             │
│   stop-notify.sh / notify-toast.ps1              │
│                                                  │
│   写文件:                                         │
│   .aiagents/state/current.json                   │
│   .aiagents/state/events.jsonl                   │
│   .aiagents/signals/*                            │
│   .aiagents/runtime/heartbeats/*.json            │
└───────────────┬──────────────────────────────────┘
                │ fsnotify (read-only)
                │ + poll fallback
                ↓
┌─────────────────────────────────────────────────┐
│         Tauri Companion App                     │
│                                                  │
│   ┌──────────────┐   ┌──────────────────────┐  │
│   │ Rust Backend │   │  Web Frontend        │  │
│   │  - watcher   │   │  - Tray icon         │  │
│   │  - parsers   │   │  - Floating notif.   │  │
│   │  - registry  │   │  - Main window       │  │
│   │  - RPC       │←─→│  - Settings          │  │
│   │  - debounce  │   │  - (Phase 4) Pet     │  │
│   └──────┬───────┘   └──────────────────────┘  │
│          │                                       │
└──────────│───────────────────────────────────────┘
           │ 写操作走 child_process.spawn
           ↓
   bash agentctl.sh dispatch backend
   bash agentctl.sh release-without-verify ...
   bash agentctl.sh retry-other-provider ...
   touch .aiagents/signals/task_ready_*  (绕道触发)
```

**关键不变量**:
- 桌宠**只读** `.aiagents/state/` / `.aiagents/signals/` / `.aiagents/logs/`
- 桌宠**只通过** `agentctl.sh` / 信号文件**写**(与主干约定一致)
- 桌宠**不在线时** v3.1 toast 兜底仍能工作(零依赖回退路径)

---

## 3 · 桥接协议

### 读 — 桌宠 → 项目

| 文件 | 作用 | 读法 |
|---|---|---|
| `.aiagents/state/current.json` | 权威状态 | fsnotify watch + 解析 JSON |
| `.aiagents/state/events.jsonl` | 事件流(增量) | tail -F 风格,记最后一行 offset |
| `.aiagents/signals/*` | active 信号文件 | dir watch,只用于 UI 同步,不消费 |
| `.aiagents/runtime/heartbeats/*.json` | watcher 存活心跳 | poll 30s,detect stale watcher |
| `.aiagents/logs/{be|fe}_<date>.log` | 日志(详情面板) | 按需读末尾 200 行 |

**读取频率**:
- fsnotify 优先(0 延迟,事件驱动)
- poll 兜底(部分网络盘 fsnotify 不可靠时)

### 写 — 桌宠 → 项目

桌宠**绝不直接编辑** `.aiagents/state/*` 或 `.aiagents/signals/*`(避免与主干约定脱节)。所有写操作走以下白名单:

| 动作 | 命令 | 触发场景 |
|---|---|---|
| 派后端任务 | `bash .aiagents/bin/agentctl.sh dispatch backend [--provider X]` | 主窗口 toolbar 按钮 |
| 派前端任务 | `bash .aiagents/bin/agentctl.sh dispatch frontend` | 同上 |
| 派修复 | `bash .aiagents/bin/agentctl.sh dispatch backend bugfix` | 同上 |
| 收下(放行) | `bash .aiagents/bin/agentctl.sh release-without-verify <agent> "<reason>"` | 浮动通知按钮 |
| 切对家 | `bash .aiagents/bin/agentctl.sh retry-other-provider <agent>` | 失败时浮动通知按钮 |
| 查状态 | `bash .aiagents/bin/agentctl.sh status` | 主窗口刷新 |
| 起 watcher | `bash .aiagents/bin/agentctl.sh watch <agent>` | 项目卡片"启动监控" |
| 停 watcher | `kill <worker.pid>` (从 workers.json 读) | 项目卡片"停止监控" |

**安全**: 命令白名单**硬编码**在 Rust backend,Web frontend 只能调名字 + 受控参数,不允许任意 shell 命令注入。

---

## 4 · 状态机映射

`.aiagents/state/current.json` 的 `<agent>.state` 字段 → 桌宠 UI:

| state | 桌宠角色表情(Phase 4) | 浮动通知 | 主要动作按钮 |
|---|---|---|---|
| `idle` | 😴 / 不显示 | 无 | (无) |
| `queued` / `queued-bugfix` | 🕐 等待 | 无(等 running) | (无) |
| `running` | 🏃 工作中 | 无 | "查看日志" |
| `done-awaiting-review` | 🎓 完成 | 弹卡片 | **[去审查]** [详情] [忽略] |
| `claude-verifying` | 🔍 验证中 | 无(主 Claude 自己在跑,不打断) | (无) |
| `ready-for-human` | 🟢 等拍板 | 弹卡片(sentinel 去重) | **[收下]** [打回] [推迟] [详情] |
| `failed` | ❌ 失败 | 弹卡片 | **[查日志]** [retry-other-provider] [bugfix] |
| `timeout` | ⏰ 超时 | 弹卡片(含 stop-notify 诊断摘要) | **[看诊断]** [retry-other-provider] |

**通知去重**: 同一 state 转换只通知一次(用 `last_notified_state_<agent>` 缓存),离开后再进可重新通知(同 v3.1.1 sentinel 思路)。

---

## 5 · UI 形态

### 5.1 系统托盘图标(常驻)

- 图标颜色随**最高优先级状态**变化:
  - 灰色: 全部 idle
  - 蓝色: 有 running
  - 黄色: 有 timeout
  - 绿色: 有 ready-for-human / done-awaiting-review
  - 红色: 有 failed
- 右键菜单:
  - 显示主窗口
  - 项目列表(每项: 状态 emoji + 项目名,点击聚焦)
  - 设置
  - 退出

### 5.2 浮动通知卡片

- 屏幕右下角(默认),支持位置配置(右上 / 左下 / 左上)
- 尺寸: 320×140px
- 含:
  - 顶部: 项目名 + agent + status(emoji + 文字)
  - 中部: 状态切换的 message(从 events.jsonl 读)
  - 底部: 1-3 个动作按钮(按状态白名单)
  - 关闭 [×] 按钮(右上角,鼠标悬浮才显示)
- 行为:
  - **不会自动消失**(用户必须点动作或 ×)
  - 多个堆叠(最多 5 个,超出滚动)
  - 鼠标悬浮高亮 + 显示完整文本
  - 点击空白处不关闭(防误触)

### 5.3 主窗口(点击托盘图标打开)

```
┌──────────────────────────────────────────────────────┐
│  ai-agents Companion                          [_□×] │
├────────────────┬─────────────────────────────────────┤
│ Projects       │ choseStock                          │
│ ┌────────────┐ │ ─────────────────────────────────── │
│ │ 🟢 chose…  │ │ Backend  state=ready-for-human  cl..│
│ │ 😴 myproj  │ │ Frontend state=idle             cl..│
│ │ ⏰ otherp  │ │                                     │
│ │            │ │ Active task: 02-后端编码.md         │
│ │ + 添加     │ │ Worker: running pid=250453          │
│ └────────────┘ │ Last heartbeat: 2s ago              │
│                │                                     │
│                │ ┌─Recent events ─────────────────┐  │
│                │ │ 08:20 [be] verify 全过        │  │
│                │ │ 07:50 [fe] done (rc=0)         │  │
│                │ │ 07:22 [be] done (rc=0)         │  │
│                │ │ 07:15 [be] wait-expired 540s   │  │
│                │ └────────────────────────────────┘  │
│                │                                     │
│                │ [Dispatch BE] [Dispatch FE] [Status]│
└────────────────┴─────────────────────────────────────┘
```

### 5.4 设置面板

- 项目注册(增删改 path)
- 通知开关(全局/按项目/按状态)
- 浮动卡片位置 + 最大堆叠数
- 启动行为(开机自启 / 最小化到托盘)
- (Phase 4) 桌宠角色开关 + 选皮肤

---

## 6 · 多项目支持

注册表 `~/.config/ai-agents-companion/settings.toml`(Win 上 `%APPDATA%/ai-agents-companion/settings.toml`):

```toml
[ui]
floating_position = "bottom-right"
max_floating = 5
notify_states = ["done-awaiting-review", "ready-for-human", "failed", "timeout"]
launch_at_startup = true

[[project]]
name = "choseStock"
path = "D:/dev/ai/workspace/choseStock"
enabled = true
auto_open_claude_code = true   # 点"去审查"时自动开 Claude Code

[[project]]
name = "another"
path = "C:/projects/foo"
enabled = false
```

每个 enabled 项目:
- 一个独立 fsnotify watcher(Rust async task)
- 共享 events 总线 → UI thread

---

## 7 · 项目结构(独立目录,不影响主干)

```
ai-agents-kit/
├── templates/              ← 现有,完全不动
├── install.sh              ← 现有,不动
├── docs/
│   ├── designs/
│   │   └── 2026-05-10-tauri-companion-design.md   ← 本文档
│   └── plans/
│       └── 2026-05-10-tauri-companion-impl.md     ← 阶段实施计划
└── companion/              ← NEW,本次新增唯一目录
    ├── README.md
    ├── .gitignore
    ├── package.json        ← Phase 1 时 npm init 后产生
    ├── src-tauri/          ← Phase 1 时 cargo + tauri init 后产生
    │   ├── Cargo.toml
    │   ├── tauri.conf.json
    │   └── src/
    │       ├── main.rs
    │       ├── watcher.rs
    │       ├── parsers.rs
    │       ├── registry.rs
    │       └── commands.rs
    └── src/                ← 前端
        ├── index.html
        ├── main.tsx        ← React + Vite
        ├── components/
        │   ├── FloatingCard.tsx
        │   ├── MainWindow.tsx
        │   ├── ProjectList.tsx
        │   └── EventStream.tsx
        └── styles/
```

---

## 8 · 与主干零耦合保证

| 保证 | 实现 |
|---|---|
| **桌宠未启动** | toast 兜底(NotifyIcon BalloonTip)继续工作 |
| **桌宠崩溃** | 不影响 watcher / runner / hook;主流程独立 |
| **桌宠卸载** | 删 `companion/` 目录即可;ai-agents-kit 主干无残留依赖 |
| **kit 升级** | install.sh 不触桌宠;桌宠独立 release |
| **桌宠不存在的项目** | 桌宠自动忽略,不影响其他项目 |

**install.sh 不强制装桌宠** — 安装结尾**只输出一行提示**:

```
🐉 想要浮动通知 + 多项目监控? 看 companion/README.md (可选)
```

不加 flag,不下载,零摩擦。

---

## 9 · 安全模型

### 9.1 命令白名单(Rust 端硬编码)

```rust
// companion/src-tauri/src/commands.rs
const ALLOWED_AGENTCTL_SUBCOMMANDS: &[&str] = &[
    "status",
    "dispatch",
    "wait",
    "watch",
    "memory",
    "release-without-verify",
    "retry-other-provider",
];

fn run_agentctl(project_path: &Path, subcommand: &str, args: &[&str]) -> Result<...> {
    if !ALLOWED_AGENTCTL_SUBCOMMANDS.contains(&subcommand) {
        return Err("subcommand not allowed");
    }
    // 限制参数: 只能是 backend/frontend/<provider name from whitelist>/...
    // 命令拼接时用 std::process::Command,不走 shell,无注入风险
    Command::new("bash")
        .arg(project_path.join(".aiagents/bin/agentctl.sh"))
        .arg(subcommand)
        .args(args)
        .current_dir(project_path)
        .spawn()
}
```

### 9.2 路径校验

- 项目 path 必须存在 + 必须含 `.aiagents/bin/agentctl.sh`(否则注册失败)
- 不允许 path 含 shell 元字符(`;` `|` `&` `$` etc)
- Rust `std::path::Path` canonicalize 防止 `..` 越界

### 9.3 IPC 白名单

Tauri `#[tauri::command]` 暴露给前端的命令也是白名单:

```rust
#[tauri::command]
fn dispatch(project_id: u32, agent: String, provider: Option<String>) -> Result<...>

#[tauri::command]
fn release_without_verify(project_id: u32, agent: String, reason: String) -> Result<...>

#[tauri::command]
fn open_in_claude_code(project_id: u32) -> Result<...>
```

前端无法调任意 Rust 函数,只能调暴露的 7-8 个 command。

---

## 10 · 测试策略

| 层级 | 范围 | 工具 |
|---|---|---|
| Unit | parsers (state.json/events.jsonl) | Rust `cargo test` |
| Unit | path validation / command whitelist | Rust `cargo test` |
| Integration | mock 项目目录 + state 切换 → 桌宠收到事件 | Rust `tokio::test` + `tempdir` |
| E2E | choseStock 真实项目 + 手测 UI | 人工剧本 |
| Smoke | tauri build → 单可执行文件能跑 | CI 脚本 |

---

## 11 · 阶段分解(详见 `docs/plans/2026-05-10-tauri-companion-impl.md`)

| Phase | 范围 | 工作量 | 交付 |
|---|---|---|---|
| **0** | 设计文档 + 实施计划 + 目录骨架 | 4h(本次)| `docs/designs/` + `docs/plans/` + `companion/README.md` |
| **1** | MVP — 单项目 watcher + 托盘 + 浮动通知 + "去审查" | 2-3 天 | 可运行 .exe,choseStock 实测 |
| **2** | 多项目注册 + 主窗口 + 设置面板 | 1 天 | settings.toml + 主窗口 UI |
| **3** | 完整交互动作(release / retry-other-provider / dispatch) | 1 天 | 浮动卡片所有按钮可用 |
| **4** | 桌宠角色 + 动画(可选) | 1-2 天 | 透明窗口 + 状态动画 |

每个 Phase 独立 commit + 独立 tag(`companion-phase-1`, ...),不跟 ai-agents-kit 主干 v3.x.y tag 链。

---

## 12 · 风险评估

| 风险 | 缓解 |
|---|---|
| Tauri 学习成本 | 用 `create-tauri-app` 模板;Rust 部分主要是 fsnotify + 命令调用,不深入 |
| Windows WebView2 依赖 | Win10/11 默认装,Win10 早期版需要安装(installer 自动检测) |
| 多项目时资源占用 | 每个 project 一个 fsnotify watcher,100 项目内忽略不计;UI 只显示 enabled 项目 |
| 通知风暴 | debounce 200ms + state 优先(只 state 转换才弹,event 高频不弹) |
| 跨平台(macOS/Linux 也要用?) | Phase 1 仅 Windows;后续按需扩(Tauri 跨平台原生) |
| 用户不想装桌宠 | Phase 0 完成后**不强制**;v3.1 toast 兜底永远生效 |
| AI Agent 误调命令 | 命令白名单 + 路径校验 + 无 shell 拼接,无法注入 |

---

## 13 · 取舍

### 为什么 Tauri 而非 Electron?

| 维度 | Tauri | Electron |
|---|---|---|
| 安装包大小 | ~20MB | ~130MB |
| 内存占用 | 低(WebView2 + Rust)| 高(Node + Chromium)|
| 开发体验 | Rust 后端学习成本 | JS 单语言 |
| 跨平台 | ✅ | ✅ |
| **结论** | **首选** — 轻量 + 性能好,Rust 后端类型安全 | 备选 — 若 Tauri 开发受阻可切 |

### 为什么不用 systray-rs / NotifyIcon 直接做?

- 纯 systray 没有浮动卡片 UI 能力(只能弹原生 toast,即 v3.1 已有的)
- WebView 给了我们用 React/Tailwind 设计 UI 的灵活性
- 主窗口要做项目列表 + events 流,纯 native widget 体验差

### 为什么独立 track 不并入 v3.1.x?

- 桌宠**可选**,不应捆绑主干升级
- 主干 Bash + PowerShell 路径必须保持简洁,加 Tauri 增加部署摩擦
- 桌宠迭代节奏慢于主干(主干每周可能多次 patch)

### 为什么 Phase 4 桌宠角色独立?

- 核心功能(浮动通知 + 主窗口)Phase 1-3 就够用
- 桌宠角色是"情感反馈",非必需
- 美术资源(透明动画 PNG / sprite)需要单独制作

---

## 14 · Approval Gate

**Lane 决定后才进 Phase 1**:

- [ ] 方向认可(Tauri + 独立 track + 命令白名单)
- [ ] 优先级排序(Phase 顺序是否需要调换?)
- [ ] 美术资源(Phase 4 桌宠形象 — 自己做 / 外包 / 用现成开源资源)
- [ ] 是否包含 macOS / Linux(影响 Phase 1 工程量)

批准后,我会:
1. 在 `companion/` 跑 `npm create tauri-app` 初始化(Phase 1 第一步)
2. 单独 commit + tag `companion-phase-1-init`
3. 按计划逐 step 实施 Phase 1
