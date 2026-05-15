# ai-agents-kit (v3)

三 Agent 协作工作流的**可安装工具包**。Claude Code 当总指挥,前后端编码 agent 可灵活选 编码 agent (codex/claude) Code(Gemini 留扩展点)。v3 在 v2 基础上引入 multi-provider 抽象 + Pre-Human Decision Gate(主 Claude 真打验证关卡)+ Handover 机制(provider 切换接续)。

## 它是什么

这个目录(`C:\Users\mi\ai-agents-kit\`)是**工具包本身**,类似 `create-react-app` 之类的脚手架。它**不是**你的项目代码,放在哪都行,只要你的项目能访问它就可以。

通过 `install.sh` / `install.ps1` 把模板幂等安装到目标项目,**目标项目不会依赖这个目录**(安装后可以把 kit 挪走或删掉,项目仍能独立运行)。

## v3.4.1 — 副 agent model 选择支持(2026-05-10)

**痛点**: 主 Claude 想用 Opus 4.6,副编码 agent 想用 Sonnet(省 token + 编码任务足够),但 kit 没法配:
- 主 Claude — Claude Code 客户端自己控制(`/model opus-4-6`)
- 副编码 agent — 调 `claude -p` / `codex exec` 时不传 `--model` 参数,只用 CLI 默认

**修复**: `--model` 参数贯穿全链, 三层优先级:

```
dispatch --model flag (临时覆盖)
  > agents.<a>.model (per-agent 默认, config.json)
    > providers.<p>.model (per-provider 默认, config.json)
      > 空 (CLI 用它自己的默认 model)
```

### 用法 — 三种粒度

**临时覆盖(单次任务)**:
```bash
/dispatch-backend --provider claude --model sonnet
/dispatch-frontend --model haiku             # 前端任务轻量, 省钱
/dispatch-backend --model claude-sonnet-4-5  # 完整模型名也行
```

**per-agent 默认(常用配置)** — 编辑 `.aiagents/config.json`:
```json
{
  "agents": {
    "backend":  {"dir": "stock-be", "provider": "claude", "model": "sonnet"},
    "frontend": {"dir": "stock-fe", "provider": "claude", "model": "haiku"}
  }
}
```
之后 `/dispatch-backend` 自动用 sonnet, `/dispatch-frontend` 用 haiku, 无需每次显式传。

**per-provider 默认(全局)** — 编辑 `.aiagents/config.json`:
```json
{
  "providers": {
    "claude": {"bin": "claude", "args": "--dangerously-skip-permissions", "model": "sonnet"},
    "codex":  {"bin": "codex",  "args": "--sandbox danger-full-access --skip-git-repo-check", "model": ""}
  }
}
```
所有走 claude provider 的任务都用 sonnet, 除非 agent/dispatch 层覆盖。

### 典型场景: 主 Opus + 副 Sonnet

**第一步 — 主 Claude 用 Opus**(Claude Code 客户端控制,跟 kit 无关):
- 命令行: `claude --model opus-4-6 .`
- 或客户端内: `/model opus-4-6`
- 或 Claude Code settings.json: `"model": "claude-opus-4-6"`

**第二步 — 副编码 agent 用 Sonnet**(改 `.aiagents/config.json`):
```json
{
  "agents": {
    "backend":  {"provider": "claude", "model": "sonnet"},
    "frontend": {"provider": "claude", "model": "sonnet"}
  }
}
```

之后:
- 主 Claude 跟 Lane 对话 / 审查 / 拆 spec 都用 Opus(贵但聪明)
- 后端 / 前端编码任务用 Sonnet(便宜 + 编码够用)

### 实现要点

| 文件 | 改动 |
|---|---|
| `agentctl.sh` | `dispatch --model X` flag 解析 |
| `agent-runner.sh` | `PROVIDER_MODEL` 三层 fallback (MODEL_OVERRIDE → agents.X.model → providers.X.model) |
| `watch-agent.sh` | `parse_signal_overrides` 加 MODEL_OVERRIDE 字段 |
| `providers/claude.sh` | build_cmd 拼 `--model $PROVIDER_MODEL` |
| `providers/codex.sh` | 同样(codex CLI 也支持 --model,可选 GPT-5 系列) |
| `install.sh` | config.json schema 加 `"model": ""` 占位 |
| `dispatch-backend.md` / `dispatch-frontend.md` | 用法说明 + 优先级表 |

### 已装项目升级

```bash
cd D:/dev/ai/workspace/your-project
bash /c/Users/mi/ai-agents-kit/install.sh --yes      # 幂等, 保留现有 config
# 然后编辑 .aiagents/config.json 加 model 字段 (install 不会自动加, 因为已有 config 跳过 rewrite)
```

## v3.4.0 — 自动轮询 + 角色名通用化 + 迁移指南(2026-05-10)

**3 个改动**:

### 1. `dispatch-*` / `bugfix-*` slash command 加 `/loop` 自动轮询

**痛点**: 派单后 `wait` 9 分钟没等到 → 主 Claude exit → 即使编码 agent 后来完成,Lane 不发消息主 Claude 永远不知道。

**修复**: dispatch/bugfix slash command 退出码 = 3 (9 分钟内无信号) 分支改成:

> 调用 Skill tool `skill=loop, args="5m /status"` 启动自动轮询。loop 每 5 分钟唤醒主 Claude 跑 `/status`,检测到 `state == done-awaiting-review` 后自动审查 + 推到 `ready-for-human` + 停 loop。Lane 可以离开,完成时桌面 toast 通知。

降级 fallback: 若 `loop` skill 不可用,告知 Lane 手动敲 `/loop 5m /status`。

### 2. "Codex" 角色名 → "编码 agent" 通用化

**痛点**: multi-provider 后编码 agent 可以是 codex 也可以是 claude,但日志/文档/状态消息全写"Codex" — 用 claude 时词不达意。

**修复**: 20 个文件批量替换角色名 "Codex" → "编码 agent" / "Backend 编码 agent" / "Frontend 编码 agent"。保留**合法用途**:
- `Codex CLI` — 产品名
- `providers.codex.args` / `CODEX_BIN` / `CODEX_ARGS` — 配置 key
- `Codex reads prompt` / `Codex-specific override` — codex 特定行为说明

新文案样例:
```
旧: "Codex-Backend 完成 → 立即审查"
新: "Backend 编码 agent 完成 → 立即审查"

旧: "[Stop hook] 检测到 Codex 状态变化"
新: "[Stop hook] 检测到编码 agent 状态变化"

旧: "Codex-$AGENT watcher ready"
新: "$AGENT 编码 agent watcher ready"
```

### 3. 跨机器迁移指南(写到 README)

见下方"迁移到另一台电脑"段落。

---

## 迁移到另一台电脑

ai-agents-kit 是**工具包**(`C:/Users/mi/ai-agents-kit/`),你的项目是**目标项目**(如 `D:/dev/ai/workspace/choseStock`)。两个都要迁。

### 1. 工具包(ai-agents-kit)迁移

**推荐: GitLab / GitHub 远程仓库**(已是 git repo, 直接 push):

```bash
# 旧电脑 — 推到 GitLab 私有仓库
cd C:/Users/mi/ai-agents-kit
git remote add origin git@gitlab.com:your-username/ai-agents-kit.git
git push -u origin master
git push --tags     # tag 一起推 (v3.0.0 ~ v3.4.0 + companion-phase-0)

# 新电脑 — clone
cd C:/Users/your-name/    # 或 ~/dev/tools/
git clone git@gitlab.com:your-username/ai-agents-kit.git
```

**备选: 直接拷文件**(无 git 仓库,如离线场景):

```bash
# 旧电脑 — 打包 (排除 .git 也可,如果不在乎历史)
cd C:/Users/mi/
tar czf ai-agents-kit.tar.gz --exclude='.git' ai-agents-kit/
# 通过 U 盘 / 网盘 / scp 拷过去

# 新电脑 — 解包到任意目录
cd ~/dev/tools/
tar xzf /path/to/ai-agents-kit.tar.gz
```

### 2. 新电脑依赖检查

ai-agents-kit 需要这些工具,新电脑装一下:

| 工具 | 必须 | 用途 | 验证 |
|---|---|---|---|
| `bash` (4.x+) | ✅ | 主脚本 | `bash --version` |
| `python` (3.7+) | ✅ | JSON 状态处理 | `python -c "import json; print('ok')"` |
| `jq` | 推荐 | install.sh 优先用,缺少 fallback python | `jq --version` |
| `git` | ✅ | watcher / agent-runner 调 | `git --version` |
| `codex` CLI | 看 provider | 后端选 codex 时需要 | `codex --version` |
| `claude` CLI | 看 provider | 后端选 claude 时需要 | `claude --version` |
| `pwsh` (PowerShell 7+) | 可选 | 桌面通知 + Windows 后台 watcher | `pwsh --version` |
| `BurntToast` (PS module) | 可选 | 更漂亮的 Toast (没装走 NotifyIcon 兜底) | `Get-Module -ListAvailable BurntToast` |

Windows 新电脑标准安装顺序:
```bash
# 1. Git for Windows (自带 bash + git): https://git-scm.com/download/win
# 2. Python: https://www.python.org/downloads/ (装时勾 "Add to PATH")
# 3. jq: scoop install jq  或  https://jqlang.github.io/jq/download/
# 4. PowerShell 7: winget install Microsoft.PowerShell
# 5. codex / claude CLI 按各自文档
# 6. (可选) BurntToast:
#    pwsh -Command "Install-Module BurntToast -Scope CurrentUser -Force"
```

### 3. 目标项目迁移

每个用 ai-agents-kit 的项目是**独立 git repo**(如 choseStock),迁移就跟普通项目一样:

```bash
# 旧电脑 (项目已有 git origin)
cd D:/dev/ai/workspace/choseStock
git push origin master
git push --tags

# 新电脑
cd ~/dev/ai/workspace/    # 或任意位置
git clone git@gitlab.com:your-username/choseStock.git
cd choseStock

# 重要 — 跑一次 install.sh 让 .aiagents/bin/ 等基础设施"重新指向"新电脑路径:
bash /path/to/new/ai-agents-kit/install.sh --yes
```

install.sh 是**幂等**的:
- 已有 `.aiagents/config.json` (v3 schema) → 跳过 rewrite, 保留你的 backend/frontend dir / stack / 命令配置 ✅
- 已有 `memory/*.md` → 不覆盖 ✅
- 已有 `docs/ai-agents/specs/*` → 不覆盖 ✅
- 仅刷新 `.aiagents/bin/*` 脚本(基础设施)和 slash commands

### 4. 验证

```bash
cd /new/path/to/your-project
bash .aiagents/bin/agentctl.sh status         # 看到 backend/frontend + provider 三栏 → OK
bash .aiagents/bin/agentctl.sh logs           # 看到日志路径 snapshot → OK
```

### 5. 注意事项

| 项 | 说明 |
|---|---|
| **bash 绝对路径** | 新电脑安装 ai-agents-kit 的路径不同,记得改本地 .bashrc / 各种快捷方式里的 `/c/Users/mi/ai-agents-kit/` 路径 |
| **node_modules / target/** | 项目里的 node_modules / Maven target / `.venv` 不要从旧电脑 git 推过来 (一般 `.gitignore` 已排除),新电脑跑 `npm install` / `mvn install` / `poetry install` 重建即可 |
| **API key** | codex / claude CLI 的 token / API key 是用户级配置,需要新电脑重新 login (`codex auth login` / `claude login`) |
| **API contract / 业务数据** | 跟项目走,git 推就好 |
| **memory 跨项目复用** | `.aiagents/memory/global/{patterns,bugs}.md` 是项目内的,但你想在多个项目共享(如 patterns.md)? 手动拷过去/写一个同步脚本,kit 暂无内建支持 |

## v3.3.1 — Codex 默认 args 修复 Windows sandbox 卡死(2026-05-10)

**痛点**: 全新装项目 codex 默认 args `--full-auto` 在 Windows 上会触 sandbox 卡死, 所有 PowerShell 命令(连 `pwd`/`Get-Location`)都失败:

```
# Codex Backend Blocked
## 阻塞原因
当前会话无法启动任何 PowerShell 命令, 最小命令 `pwd` 与 `Get-Location` 均失败
```

memory bugs.md 之前记过("agents.conf 改回 --full-auto → Windows sandbox 卡死"), 但默认值一直没修, README 只有警告没解决。

**修复**: 4 处默认值全部改成 `--sandbox danger-full-access --skip-git-repo-check`:

| 文件 | 改动 |
|---|---|
| `install.sh:278` | `CODEX_ARGS_DEFAULT` 默认值 |
| `install.ps1:21` | `$CodexArgs` 顶部 param 默认 |
| `templates/.aiagents/bin/agentctl.ps1:61` | KV fallback (config.json 不存在时兜底) |
| `templates/.aiagents/bin/agent-runner.sh:105` | 终极兜底 (所有路径都没设 args 时) |

**新 args 含义**:
- `--sandbox danger-full-access`: sandbox 模式但允许全访问宿主(替代老 `--dangerously-bypass-approvals-and-sandbox`)
- `--skip-git-repo-check`: 跳过 git 仓库检查 (`.aiagents/runtime` 等非 git 子目录不再报错)

**已装项目影响**:

| 项目 | 行为 |
|---|---|
| 全新空项目 | `bash install.sh --yes` 装出来就是正确值, 不会再卡死 |
| 已有 v3 config.json 项目 | install 跳过 rewrite 不影响 — 但要主动修, 见下面"补丁修复" |

**补丁修复已装项目** (yuqiSite / choseStock 等):

```bash
# 法 1: 编辑 .aiagents/config.json 把 providers.codex.args 改成新值
# 法 2: 简单粗暴 — 删 config.json + agents.conf 重装
cd /path/to/your/project
rm -f .aiagents/config.json .claude/agents.conf
bash /c/Users/mi/ai-agents-kit/install.sh --yes
```

## v3.3.0 — 默认轻量栈 + `--stack` 预设(2026-05-10)

**痛点**: 装新空项目时默认 Spring Boot 3.x + JPA(重型 Java),Lane 反馈"我不只是 ERP / 大型项目,中小项目应该用 python 等轻量"。

**修复**:

1. **默认值全面轻量化** — `--yes` 模式空项目不再装 Spring Boot,默认 `python-light`:
   - 后端: `FastAPI + SQLAlchemy` / `pytest` / `ruff check .`
   - 前端: `Vite + React` / `npm test` / `npm run lint`
   - 对齐 choseStock 实战栈

2. **`--stack` flag** — 非交互模式可指定预设:

```bash
bash install.sh --yes                                # python-light (默认)
bash install.sh --yes --stack python-poetry          # poetry 包管
bash install.sh --yes --stack go                     # Go+Gin + React
bash install.sh --yes --stack node-fullstack         # Fastify + Next.js
bash install.sh --yes --stack java-enterprise       # 重型 Spring Boot Maven
bash install.sh --yes --stack java-gradle           # Spring Boot Gradle
```

PowerShell 等价:
```powershell
pwsh install.ps1 -Yes -Stack python-light
pwsh install.ps1 -Yes -Stack java-enterprise
```

3. **交互式问询重排 + 分组** — 不带 `--yes` 时按"中小 → 中型 → 重型"分三组列出,默认选项指向 Python(原默认是 Java):

```
📦 选一个起手栈:

  ── 中小项目 / 个人项目 / 内部工具 (推荐轻量栈):
    1) Python FastAPI + Vite+React              [默认]  对齐 choseStock 实战栈
    2) Python FastAPI (Poetry) + Vite+React              用 poetry 管包
  ── 中型企业 / 团队协作:
    3) Go (Gin) + Vite+React                             高性能轻量
    4) Node.js (Fastify) + Next.js                       全栈 JS
  ── 重型企业 / 大型系统:
    5) Java (Spring Boot 3 / Maven) + Vite+React         传统重型 Java
    6) Java (Spring Boot 3 / Gradle) + Vite+React
```

**改动文件**:
- `install.sh`: `--stack` 解析 + `apply_stack_preset()` helper + ask 默认值 + choose_preset 重排
- `install.ps1`: `-Stack` 参数 + `Apply-StackPreset` + Ask 默认值 + 交互菜单重排
- `templates/.claude/agents.conf`: KV 默认值改 FastAPI 系
- `--help` / `-h` flag(install.sh)显示完整 stack 选项

**已装项目不影响**: install.sh 检测到 v3 schema config.json 时跳过 rewrite(`[install] config.json is already v3 -- skipping rewrite`),choseStock 等已安装项目不会被重置。

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
bash /c/Users/mi/ai-agents-kit/install.sh --yes
```

**v3.3.1 后默认值已修正**: install.sh `CODEX_ARGS` 默认 `--sandbox danger-full-access --skip-git-repo-check`(替代老 `--full-auto`,免 Windows sandbox 卡死)。v2 项目走 migration 时旧 `codex.args` 值**自动保留**,如果想用新值需手动改 `.aiagents/config.json` 或删 config 重装。

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
- **反馈**: 编码 agent 完成后 runner 写 `*_done` 信号 + done 事件 + 更新 state。Claude 下次 turn 结束时 **Stop hook** 检测到信号 + 摘录 state 注入"请审查"提示
- **审查**: Claude 按 **Karpathy 6 原则**(A 执行验证 / B Think / C Simplicity / D Surgical / E Goal-Driven / F Sanity)逐项核查
- **修复**: 审查失败 → 生成 `04-Bug修复-*.md` → `/bugfix-*` 再派编码 agent → 最多 3 轮
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
