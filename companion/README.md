# ai-agents-companion (独立 track,Phase 0 设计中)

ai-agents-kit 的可选**桌面伴侣 app**:浮动通知 + 多项目监控 + 交互动作。

## 它是什么

主干 `ai-agents-kit` 是 Bash/PowerShell 工作流,通过 `.aiagents/state/*` 协调三 agent。当主 Claude 离线时,v3.1 的 NotifyIcon Toast 是唯一的通知通道,但有 3 个痛点:

1. **8 秒消失** — 用户离开座位回来就丢
2. **不能交互** — 只是文字提示,不能点"去审查 / release / retry"
3. **单项目** — 只能监控当前 cwd

`ai-agents-companion` 用 **Tauri (Rust + WebView)** 给主干加一个**可选**的桌面伴侣层:

- 🪟 **浮动通知卡片** — 长驻直到用户处理
- 🖱️ **交互按钮** — 去审查 / 收下 / 打回 / retry-other-provider
- 📋 **多项目监控** — 同时跟 N 个项目
- 🐉 (Phase 4 可选) **桌宠角色** — 状态情感反馈

## 与主干的关系

| 维度 | 状态 |
|---|---|
| 主干代码 | **零修改** — `templates/` / `install.sh` 一字不动 |
| 主干工作流 | 独立 — 桌宠未启动时 v3.1 toast 兜底仍生效 |
| 卸载 | 删本目录即可,主干无残留依赖 |
| 升级节奏 | 与主干 v3.x.y tag 链解耦 — 用 `companion-phase-N-*` |

## 当前状态

**Phase 0 — 设计 + 骨架(进行中)**

| 文档 | 路径 |
|---|---|
| 设计方案 | [`docs/designs/2026-05-10-tauri-companion-design.md`](../docs/designs/2026-05-10-tauri-companion-design.md) |
| 实施计划 | [`docs/plans/2026-05-10-tauri-companion-impl.md`](../docs/plans/2026-05-10-tauri-companion-impl.md) |

**等 Lane 批准后才进入 Phase 1**(工程初始化)。

## 路线图

| Phase | 范围 | 工作量 | 状态 |
|---|---|---|---|
| 0 | 设计 + 骨架 | 4h | ✅ 进行中 |
| 1 | MVP — 单项目 watcher + 托盘 + 浮动通知 + "去审查" | 2-3 天 | ⏳ 待批准 |
| 2 | 多项目注册 + 主窗口 + 设置面板 | 1 天 | ⏳ 排队 |
| 3 | 完整交互动作(release / retry / dispatch) | 1 天 | ⏳ 排队 |
| 4 | 桌宠角色 + 动画(可选) | 1-2 天 | ⏳ 排队 |

## 技术选型

- **Tauri 2.x** — Rust 后端 + WebView 前端,~20MB 安装包,跨平台
- **React + Vite + TypeScript** — 前端
- **pnpm** — 包管理
- **notify (Rust crate)** — fsnotify 跨平台
- **serde + toml** — 配置文件

## 桥接协议(简版)

```
ai-agents-kit watcher / runner
       ↓ (写文件)
.aiagents/state/current.json + events.jsonl + signals/*
       ↓ (fsnotify, read-only)
   companion app
       ↓ (spawn bash agentctl.sh ...)
ai-agents-kit agentctl
```

桌宠**只读**项目状态,**只通过 agentctl.sh 写**(和主干约定一致,无 IPC 协议)。

## 开发(Phase 1 后才适用)

```bash
# 待 Phase 1 启动后填充
cd companion
pnpm install
pnpm tauri dev
```

## 不打算做的事

- ❌ 替代 Claude Code(Claude Code 仍是主操作面)
- ❌ 与 Codex / Claude provider 直接对话(走 agentctl.sh)
- ❌ 持久化业务数据(项目自治,events.jsonl 已经够)
- ❌ 远程通知 / webhook(本机 desktop app 即可)
- ❌ 强制安装(install.sh 不会带,Lane 自己 opt-in)

## 安全模型

- 命令调用 **白名单** 硬编码(只允许 agentctl.sh 子命令)
- 路径校验 + canonicalize 防 `..` 越界
- Tauri command 白名单(前端只能调暴露的 7-8 个)
- 不走 shell 拼接,不存在注入

详见 `docs/designs/2026-05-10-tauri-companion-design.md` § 9。
