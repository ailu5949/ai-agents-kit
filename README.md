# ai-agents-kit (v2)

三 Agent 协作工作流的**可安装工具包**。Claude Code 当总指挥,两个 OpenAI Codex CLI 当前后端执行者。v2 在 v1 基础上吸收了 ai-multi-agents 项目里已落地的高价值能力(Memory 三层、JSON state、JSONL event、PowerShell 入口),保持原有的 Karpathy 6 项审查 rubric 和稳健的 jq 幂等合并不变。

## 它是什么

这个目录(`C:\Users\mi\ai-agents-kit\`)是**工具包本身**,类似 `create-react-app` 之类的脚手架。它**不是**你的项目代码,放在哪都行,只要你的项目能访问它就可以。

通过 `install.sh` / `install.ps1` 把模板幂等安装到目标项目,**目标项目不会依赖这个目录**(安装后可以把 kit 挪走或删掉,项目仍能独立运行)。

## v2 主要变化

| 维度 | v1 | v2 |
|---|---|---|
| 运行目录 | `docs/superpowers/{specs,signals,logs,bin}` | `.aiagents/{bin,signals,logs,state,runtime,memory}` + `docs/ai-agents/{specs,reviews,retrospectives}` |
| 状态判断 | 信号文件存在性 | `.aiagents/state/current.json` 的 `state` 字段(权威) |
| 事件流 | 无(只有 log) | `.aiagents/state/events.jsonl` |
| 记忆系统 | 无 | `memory/global` + `memory/projects` + `memory/ideas` 三层 |
| Slash 命令 | 7 个 (`/dispatch-*` etc.) | 9 个(增 `/memory`、`/retrospective`,命令名保持兼容) |
| 执行链 | watcher 直接跑 codex | `signal → watch-agent.sh → agent-runner.sh → codex → state/event`(显式分层) |
| Windows 入口 | 仅 Bash(WSL/Git Bash) | Bash + PowerShell 5.1+ 原生 |
| 配置 | `.claude/agents.conf`(KV) | `.aiagents/config.json`(JSON,主) + `.claude/agents.conf`(KV,兼容 fallback) |
| 审查 rubric | Karpathy 6 项(A/B/C/D/E/F) | 同上(不变) |
| 复盘 | 无 | `/retrospective` + `docs/ai-agents/retrospectives/` |

## 装到目标项目

### Bash(Linux / WSL / macOS / Cursor Git Bash)

```bash
cd /d/dev/ai/workspace/your-project
git init                                         # install.sh 依赖 git rev-parse 找项目根
bash /c/Users/mi/ai-agents-kit/install.sh        # 交互式
# 或非交互:
BACKEND_DIR=apps/api FRONTEND_DIR=apps/web bash /c/Users/mi/ai-agents-kit/install.sh --yes
```

### PowerShell(Windows 原生)

```powershell
cd D:\dev\ai\workspace\your-project
git init
pwsh C:\Users\mi\ai-agents-kit\install.ps1                                  # 交互式
pwsh C:\Users\mi\ai-agents-kit\install.ps1 -BackendDir erp-be -Yes          # 非交互
```

### 从 v1 升级(已经按旧版装好的项目)

```bash
bash /c/Users/mi/ai-agents-kit/install.sh --migrate-v1
# 或:
pwsh C:\Users\mi\ai-agents-kit\install.ps1 -MigrateV1
```

迁移脚本会平移 specs / signals / logs,升级 CLAUDE.md 的 v1 marker → v2,备份旧 bin/。

## 两种启动方式(共享一套配置)

### 方案 ② Cursor / VSCode 三终端(推荐)

```
面板 1> claude .
面板 2> bash .aiagents/bin/agentctl.sh watch backend
面板 3> bash .aiagents/bin/agentctl.sh watch frontend
```

PowerShell 等价:`pwsh .aiagents\bin\agentctl.ps1 watch backend|frontend`

### 方案 ① tmux 三窗格(Linux/WSL)

```bash
bash ./start-agents.sh
```

## 核心设计

- **触发**: Claude 通过 slash command(`/dispatch-backend` 等)调用 `agentctl.sh dispatch backend` 写信号 + 事件,**不**靠自然语言触发词
- **执行链**: `signal → watch-agent.sh → agent-runner.sh → codex → state + event`(每层职责单一,可观测)
- **状态权威**: 不是信号文件,而是 `.aiagents/state/current.json` 的 `<agent>.state` 字段
- **反馈**: Codex 完成后 runner 写 `*_done` 信号 + done 事件 + 更新 state。Claude 下次 turn 结束时 **Stop hook** 检测到信号 + 摘录 state 注入"请审查"提示
- **审查**: Claude 按 **Karpathy 6 原则**(A 执行验证 / B Think / C Simplicity / D Surgical / E Goal-Driven / F Sanity)逐项核查
- **修复**: 审查失败 → 生成 `04-Bug修复-*.md` → `/bugfix-*` 再派 Codex → 最多 3 轮
- **记忆**: 每轮任务前 Claude 读 `memory/global/{patterns,bugs}.md`、`projects/context.md`、`ideas/product-ideas.md`;`/retrospective` 把本轮经验回写

## 升级工具包(在已安装项目)

把 `ai-agents-kit/` 仓库更新后,在目标项目再跑一次 install:

```bash
bash /c/Users/mi/ai-agents-kit/install.sh
```

CLAUDE.md 的 marker 段会原地替换(自动识别 v1/v2),settings.json 用 jq 幂等合并,memory 文件已存在的不覆盖。你手动改过的部分不会丢。

## 依赖

- `bash` 4+(Linux / macOS / WSL / Git Bash)或 `pwsh` 5.1+
- `jq` **或** `python3`(脚本里的 JSON 操作,二者其一即可;两者都有最佳)
- `git`(install 脚本用 `git rev-parse` 定位项目根)
- `tmux`(仅方案①需要)
- OpenAI 官方 `codex` CLI(非交互模式 `codex exec`)
- `claude` (Claude Code CLI)

## 目录一览

```
ai-agents-kit/
├── install.sh                                # Bash 幂等安装器(含 --migrate-v1)
├── install.ps1                               # PowerShell 等价物
├── README.md                                 # 本文件
└── templates/                                # 所有模板,install 脚本复制/合并到目标项目
    ├── CLAUDE.md                             # Claude 主指令(v2 marker)
    ├── start-agents.sh                       # tmux 方案入口
    ├── .claude/
    │   ├── settings.json                     # Stop hook + permissions.allow
    │   └── commands/                         # 9 个 slash command
    └── .aiagents/
        ├── bin/                              # agentctl.{sh,ps1} / agent-runner.sh / watch-agent.sh / stop-notify.{sh,ps1} / filter-output.sh / wait-signal.sh
        └── memory/                           # global/{patterns,bugs}.md / projects/context.md / ideas/product-ideas.md
    └── docs/ai-agents/README.md              # 给用户的操作手册
```

## 与 ai-multi-agents Web Console 的关系

`D:\dev\ai\ai-multi-agents\ai-dev-platform-kit\console\` 是一个独立的 Node + vanilla JS 控制台,可监控 v2 装好的任意项目。**ai-agents-kit 不内置 console**,但**保证 schema 兼容**:

- `.aiagents/state/current.json`、`.aiagents/state/events.jsonl`、`.aiagents/runtime/heartbeats/<agent>.json` 字段命名与 console 期望读取的完全一致
- 用户可随时另启 console 接入 v2 项目,无需改代码

## 后续计划(预留,未实现)

- 多模型 Router(Claude 主脑 + GPT 补充 + 失败升级)
- Skill Registry / Module Library 跨项目复用
- Memory 向量检索(从基于 keyword 的 grep 升级到 embedding)

这些方向在 `D:\dev\ai\ai-multi-agents\gpt的多agent沟通记录.md` 里有完整设计稿,但还未落地。本工具包当前只吸收了已实际可运行的能力。
