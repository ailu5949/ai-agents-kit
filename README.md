# ai-agents-kit (v3)

三 Agent 协作工作流的**可安装工具包**。Claude Code 当总指挥,前后端编码 agent 可灵活选 Codex / Claude Code(Gemini 留扩展点)。v3 在 v2 基础上引入 multi-provider 抽象 + Pre-Human Decision Gate(主 Claude 真打验证关卡)+ Handover 机制(provider 切换接续)。

## 它是什么

这个目录(`C:\Users\mi\ai-agents-kit\`)是**工具包本身**,类似 `create-react-app` 之类的脚手架。它**不是**你的项目代码,放在哪都行,只要你的项目能访问它就可以。

通过 `install.sh` / `install.ps1` 把模板幂等安装到目标项目,**目标项目不会依赖这个目录**(安装后可以把 kit 挪走或删掉,项目仍能独立运行)。

## v3.2.2 — logs 默认过滤 stream-json 残留(2026-05-10)

**痛点**: v3.2.1 logs follow 时,如果 pretty log 里混有 stream-json 原始 JSON Lines(v3.0.1 时代旧任务残留 / 用户混用),tail -F 会刷出大量 `{"type":"system",...}` 一行 1KB+ 的难读内容。

**修复**: `logs follow pretty` **默认过滤** `^{` 开头行(stream-json Lines 都以 `{"key":` 开头,业务文本不会以 `{` 开头):

```bash
bash agentctl.sh logs backend            # 默认过滤 — 看不到 raw JSON
bash agentctl.sh logs frontend           # 同上
bash agentctl.sh logs both               # 同上

# debug 时禁用过滤 (看完整内容):
LOGS_NOFILTER=1 bash agentctl.sh logs backend
```

**作用范围**:

| kind | 默认行为 |
|---|---|
| `pretty` | 过滤 `^{` 行 (默认 ON) |
| `worker` | 不过滤 (watcher 自身 echo 不含 JSON) |
| `raw` | 不过滤 (用户明确想看原始 JSON 才会选 raw) |

实测: `fe_20260510.log` 末 5 行(全是 JSON Lines)经过滤后 0 输出,LOGS_NOFILTER=1 时正常显示。

## v3.2.1 — 日志监控子命令 (logs)(2026-05-10)

**痛点**: v3.2.0 一键 `up` 后 watcher 全后台,Lane 看不到实时执行,要手动 `tail -F .aiagents/logs/be_20260510.log`(还要每天换日期),不友好。

**修复**: 加 `logs` 子命令,封装常见监控:

```bash
# 无参数 — 列所有日志路径 + 末尾 5 行快照(不 follow)
bash .aiagents/bin/agentctl.sh logs

# follow 单个 agent(默认 pretty 流,即 codex/claude 实时输出)
bash .aiagents/bin/agentctl.sh logs backend
bash .aiagents/bin/agentctl.sh logs frontend

# 同时跟 backend + frontend(GNU tail -F 多文件,自带 banner 区分)
bash .aiagents/bin/agentctl.sh logs both

# 跟特定 kind:
bash .aiagents/bin/agentctl.sh logs backend worker  # watcher 自身 stdout (验 watcher 是否还活)
bash .aiagents/bin/agentctl.sh logs backend raw     # claude 原始 JSON Lines (debug)
```

**三种 log kind**:

| kind | 文件 | 用途 |
|---|---|---|
| `pretty`(默认) | `be_<date>.log` / `fe_<date>.log` | codex/claude 人眼可读流 — **主要监控点** |
| `worker` | `worker-{backend,frontend}.log` | watcher 自身 echo("🔔 检测到任务" 等) — 验 watcher 还活着 |
| `raw` | `be_<date>.log.raw` | claude `stream-json` 原始 JSON Lines(v3.0.2+ 双 log 启用)— debug 兜底 |

**Cursor 多 bash 协作典型布局**:

```
窗口 1: bash agentctl.sh up                 # 起 watcher (一次性)
窗口 2: bash agentctl.sh logs both          # 跟双 agent 实时 (常驻)
窗口 3: bash agentctl.sh dispatch backend   # 派任务 (按需)
窗口 4: 写代码 / git / pytest               # 主工作区
```

PowerShell 等价(`Get-Content -Wait -Tail`):
```powershell
pwsh .aiagents/bin/agentctl.ps1 logs backend
pwsh .aiagents/bin/agentctl.ps1 logs both         # 用 background job 并发跟两个文件
```

## v3.2.0 — 一键启停 (up/down/restart)(2026-05-10)

**痛点**: 冷启动每次要敲 200 字符 / 2 行的 nohup + disown 双行命令,反人类:

```bash
nohup bash .aiagents/bin/agentctl.sh watch backend  > .aiagents/logs/worker-backend.log  2>&1 < /dev/null & disown
nohup bash .aiagents/bin/agentctl.sh watch frontend > .aiagents/logs/worker-frontend.log 2>&1 < /dev/null & disown
```

**修复**: `agentctl.sh` / `agentctl.ps1` 加 `up` / `down` / `restart` 子命令:

```bash
# Bash (git-bash on Windows / Linux / macOS)
bash .aiagents/bin/agentctl.sh up        # 一键起 backend + frontend
bash .aiagents/bin/agentctl.sh down      # 一键停所有
bash .aiagents/bin/agentctl.sh restart   # down + up

# PowerShell (Windows 真后台,关窗口不影响 watcher)
pwsh .aiagents/bin/agentctl.ps1 up
pwsh .aiagents/bin/agentctl.ps1 down
pwsh .aiagents/bin/agentctl.ps1 restart
```

**字符数**: 200 → 21(Bash)/30(PowerShell),减少 ~85%。

**实现要点**:

- **幂等**: 若 worker 已在跑(`workers.json` 有 pid + `kill -0` 通过),跳过不重复启动
- **真后台**:
  - Bash 路径用 `nohup ... > log 2>&1 < /dev/null & disown`
  - PowerShell 路径用 `Start-Process -WindowStyle Hidden`(脱离当前 console,关窗口不影响)
- **stale pid 清理**: down 时 `kill -TERM` 后 0.3s 不退则 `kill -9`
- **alias**: `up` / `start` 等价,`down` / `stop` 等价

## v3.1.0 — 桌面通知层 + watcher cleanup 修复(2026-05-10)

**痛点**: 主 Claude 离线时(用户切到别的项目 / Claude Code 关闭),编码 agent 完成 / 失败 / 超时**没有任何通知**。Stop hook 只在对应项目的 Claude Code 会话里 turn 结束时触发,Lane 不在 → signal 堆积无人处理。choseStock 实战中 backend 完成 6 小时无人审查就是这个问题。

**实现**:

1. **`notify-toast.ps1`(双层兜底)**:
   - **Layer A**: BurntToast(若安装,体验最佳,ActionCenter 留底)
   - **Layer B**: NotifyIcon BalloonTip(Win10/11 原生,零依赖兜底)
   - 失败静默(没 pwsh / 抛异常都不影响主流程)

2. **agent-runner 集成**: done / failed / timeout / stale 四个出口都 background-spawn 一次 toast,不阻塞 runner。提示包含项目名 + agent + status + 下一步建议(如 "回到 Claude Code 审查")。

3. **install.sh 提示**: 安装结尾自动检测 BurntToast 是否存在,给 Lane 升级命令(`Install-Module BurntToast -Scope CurrentUser -Force`),不强制装。

**顺手修复**:

- `watch-agent.sh` cleanup trap 重复触发 bug:trap 在 EXIT/INT/TERM 都调一次,旧版无幂等 guard,一次 watcher 死亡会写 8-10 条 `watcher-stopped` 事件。加 `_cleanup_done` flag 后只写一条。

**Lane 行为变化**:

| 场景 | v3.0.4 之前 | v3.1.0 |
|---|---|---|
| backend 完成,Claude Code 关闭 | 无人知道,signal 堆积 | 右下角弹 toast `[choseStock] backend done — 回到 Claude Code 审查` |
| frontend 失败 | 主 Claude 离线时无感 | 弹 `[choseStock] frontend failed — 看 events.jsonl + log` |
| timeout 1800s | 无感 | 弹 `[choseStock] backend timeout — 看 stop-notify 注入诊断` |

## v3.0.4 — 副 agent 超时三层加固(2026-05-10)

**痛点**: 副 agent 1800s timeout 时,主 Claude 不知道 work 是否已落 / claude 是否还在跑 / 是否需要重派 — 容易误判直接重派,让 codex/claude 重做浪费 token(memory bugs.md #25/#26/#29 三次复现)。

**三层加固**:

1. **adapter 自动恢复** — `_common.sh` `default_evaluate_completion` timeout 时检测 git status:work 已落(commit/dirty)→ 自动改判 `stale`(直接进 `done-awaiting-review` 路径),不再误报 timeout。13/13 单元测试覆盖。

2. **Stop hook 自动诊断** — `stop-notify.sh` 检测到 `<agent>_timeout` signal 时,自动跑 `git status` / `git log -1` / `tail log_<date>.log` 并把结果**注入** Stop hook reason。主 Claude 看到 timeout 提示时已附诊断,无需手动查。

3. **CLAUDE.md SOP** — 加 § 副 agent 超时诊断流程 节,主 Claude 决策树覆盖 4 种 timeout 子场景(work 已落 / 还在跑 / 真失败 / 真 hang),严禁"看到 timeout 直接重派"。

**生效路径**: timeout-with-work-landed 在 adapter 层自动转 stale → 主 Claude 走标准审查;真 timeout(work 没落)经 hook 诊断后走 SOP 决策树。

## v3.0.3 — log 默认极简(只动作信号,不复述细节)— 2026-05-10

**痛点反思**: v3.0.2 把 JSON 转人眼版后,Lane 反馈"我只想知道 claude 在动还是 hang,不需要看 old_string/new_string/CoT 思考"。

**修复**: `_stream_json_pretty.py` 加 `STREAM_VERBOSE` env 控制:

| 模式 | 输出 |
|---|---|
| **默认 (minimal)** | 🟢 init / 🔧 ToolName + 短目标(文件名 / 命令头一个 token)/ ❌ tool error / ✅ result |
| **STREAM_VERBOSE=1** | 加上 💬 文本块 / 🤔 thinking / ✓ 成功 tool_result 内容 |

实测样例:

```
默认:
🟢 [init] session=abc12345 tools=6
🔧 Read trading_plan_service.py
🔧 Edit trading_plan_service.py
🔧 Bash pytest
🔧 Bash git
❌ tool error: fatal: not a git repo
✅ result · cost=$0.42 · turns=18 · success
```

文件名只显示 basename, Bash 只显示命令头一个 token。Edit 完全不显示 old_string/new_string。
设 `STREAM_VERBOSE=1` 调试时再展开细节。

raw JSON 始终落 `.log.raw`(无论 minimal / verbose),audit / 详查随时可用。

## v3.0.2 — claude log 人眼友好版(2026-05-10)

**v3.0.1 副作用**: stream-json 让 stdout 变 JSON Lines,Lane tail log 直接看是 JSON,人眼读累。

**修复**: 新增 `templates/.aiagents/bin/providers/_stream_json_pretty.py`,在 runner pipeline 内**实时**把 JSON Lines 转人眼版(`💬 文本` / `🔧 工具调用` / `✅ result · cost · turns`)。

双 log 设计:
- `.aiagents/logs/<be|fe>_<date>.log` — 人眼版(Lane / 主 Claude tail 这个)
- `.aiagents/logs/<be|fe>_<date>.log.raw` — 原始 JSON Lines(audit / debug / jq 后处理)

实测样例(本地 stream → pretty 转换):
```
🟢 [init] session=abc12345 tools=6
💬 我先看一下 trading_plan_service.py 的当前结构
🔧 Read app/services/trading_plan_service.py
✓ tool_result def existing_function(): ⏎     pass ⏎
🔧 Edit app/services/trading_plan_service.py
🔧 Bash pytest tests/test_trading_plan.py -v
✓ tool_result 5 passed in 0.3s
✅ result · cost=$0.42 · turns=18 · success
```

非 JSON 行(banner / runtime error)和未知 type 原样 pass,容错友好。codex 路径完全不动(继续走 filter-output.sh awk 过滤)。

## v3.0.1 — claude provider 流式输出(2026-05-10)

**痛点**: 副 agent 切到 claude 后,Lane / 主 Claude 卡在 watcher "🔔 检测到 backend 新任务" 提示长时间黑盒,无法判断 claude 在跑还是 hang。原因:`claude -p` 默认非流式,subprocess 跑完才一次性输出。

**修复**: `templates/.aiagents/bin/providers/claude.sh` `provider_build_cmd` 加 `--output-format stream-json --verbose`,每个工具调用 / 文本块实时进 log。

**对已有 v3.0.x 项目升级**: 重跑 `install.sh` 即可(providers/*.{sh,py} 直接覆盖,不破坏其他配置)。

## v3 主要变化(2026-05-10)

- **Provider 抽象**: `templates/.aiagents/bin/providers/{codex,claude}.sh` adapters,各实现 `provider_build_cmd` + `provider_evaluate_completion`(Gemini stub 留扩展点)
- **Per-agent default + per-dispatch override**: `agents.{backend,frontend}.provider` 默认 + `/dispatch-backend --provider claude --timeout 3600` 临时切
- **Pre-Human Decision Gate**: 三段式工作流 `done-awaiting-review → claude-verifying → ready-for-human`。主 Claude 必须**真打**跑测试 + curl smoke + E2E 全过才让 Lane 决策
- **Handover 机制**: claude 跑一半 token 不够切 codex,`runtime/<agent>-handover.md` 把"前一家做到哪儿"传给新 provider,**接续不重做**。`/retry-other-provider <agent>` 自动生成骨架
- **编码 agent 上下文隔离**: 子目录 `${BACKEND_DIR}/CLAUDE.md` + 主 `settings.json` `permissions.deny Edit/Write` 业务目录(主 Claude 不直接改业务码硬约束)
- **Stdin prompt delivery**: 突破 Codex 32KB args 上限
- **应急 bypass**: `/release-without-verify <agent> "<reason>"` 显式破例(自动写 memory/bugs.md 留痕)
- **设计文档**: [docs/designs/2026-05-09-multi-provider-design.md](docs/designs/2026-05-09-multi-provider-design.md)

详细变化请看上述 spec § 7-§ 10。

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
pwsh C:\Users\mi\ai-agents-kit\install.ps1 -BackendDir backend -Yes         # 非交互
```

### 从 v1 升级(已经按旧版装好的项目)

```bash
bash /c/Users/mi/ai-agents-kit/install.sh --migrate-v1
# 或:
pwsh C:\Users\mi\ai-agents-kit\install.ps1 -MigrateV1
```

迁移脚本会平移 specs / signals / logs,升级 CLAUDE.md 的 v1 marker → v2,备份旧 bin/。

### 从 v2 升级到 v3(2026-05-10)

直接重跑 `install.sh`(v3 自动检测 v2 config.json `codex.*` 块 → 迁移到 `providers.codex.*` + 注入 `providers.claude` 默认值,旧 `codex.args` 值**自动保留**):

```bash
cd /d/dev/ai/workspace/your-v2-project
CODEX_ARGS="--dangerously-bypass-approvals-and-sandbox" bash /c/Users/mi/ai-agents-kit/install.sh --yes
```

**注意**: install.sh fresh path 默认 CODEX_ARGS 是 `--full-auto`(Windows sandbox 卡死高风险)。已有 v2 config.json 的项目走 migration path 没问题(保留旧值);全新装务必显式 `CODEX_ARGS=--dangerously-bypass-approvals-and-sandbox`。

升级后:
- `agents.{backend,frontend}.provider` 默认 `codex`(行为零变化)
- 想切 → `/dispatch-backend --provider claude`
- 验证: `bash .aiagents/bin/agentctl.sh status` 输出含 `provider:` 列

**install.ps1 v3 mirror 推迟到 v3.1**:PowerShell 用户暂用 Git Bash 跑 install.sh。升级后 `agentctl.ps1 -Provider <name>` 已支持(Task 3.3)。

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
