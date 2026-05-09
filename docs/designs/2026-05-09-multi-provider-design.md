# Multi-Provider CLI 切换 — Design

> 让前端 / 后端编码 agent 灵活切 Codex / Claude Code(后续 Gemini),并把"主 Claude 验证关卡"作为人工决策前的硬门控。
>
> 状态: design 已与用户确认,待落 plan 后实施。

## 1. 上下文

### 1.1 当前痛点

choseStock 实战(memory 沉淀):

- 编码 agent 只支持 Codex,有些任务用 Claude Code 写更快,无法切换
- 主 Claude 审查时存在"形式化通过 vs 真打验证" 二档差异;ready 给 Lane 时不一定真跑过测试
- Lane 等主 Claude 提醒时"看不到任何状态",窗口被埋在桌面深处错过决策时机

### 1.2 目标

1. 引入 provider 抽象层:`backend.provider` / `frontend.provider` 可独立选 codex / claude / gemini
2. 派单时支持运行时覆盖:`/dispatch-backend --provider claude`
3. 强化主 Claude 审查为**真打验证关卡**(Pre-Human Decision Gate),验证全过才推进 `ready-for-human`
4. 编码 agent 与主 agent **进程 + prompt + 工具权限**三层隔离,multi-provider 不污染主 Claude 上下文
5. 桌宠状态提醒 — 本期 _DEFERRED,先确保新 state 字段为后续 UI 客户端 ready

### 1.3 用户决策记录(brainstorm Q1-Q7 拍板)

| # | 决策点 | 选项 |
|---|---|---|
| Q1 | 灵活粒度 | **D**: agent 级默认 + 派单级覆盖 |
| Q2 | 第一版支持范围 | **B**: Codex + Claude Code 内置,Gemini 留扩展点 |
| Q3 | Schema 形态 | **X**: 命名空间式(`providers.{name}` 块) |
| Q4 | 派单语法 | **P**: flag 形式(`--provider claude`) |
| Q5 | Prompt 传递 | **A**: 默认 stdin + 位置参数 fallback |
| Q6 | Claude Code 默认权限 | **A**: `--dangerously-skip-permissions`(对齐 Codex bypass) |
| Q7 | Provider 在 state/event 曝光 | **A**: 曝光,审查报告含 `**Provider**:` 字段 |

后续追加约束:

- **R1**: 主 agent 与编码 agent 必须分开管理,避免上下文污染(§ 8 编码 agent 隔离)
- **R2**: 主 Claude 必须遵守严格审查规则(§ 9 主 Claude 帮编码硬约束 + § 10 Pre-Human Decision Gate)
- **R3**: 人工决策前主 Claude 必须真打验证通过接口/测试(§ 10 三段式工作流)
- **R4**: 桌宠 / 状态提醒 _DEFERRED,本期不实施(§ _DEFERRED)

## 2. 整体架构

```
┌─ slash command (--provider 覆盖)
│
├─ agentctl.sh dispatch backend --provider claude --timeout 3600
│           ↓
│  signal: backend_ready (含 provider 元数据)
│           ↓
├─ watch-agent.sh 唯一变化:把 provider 透传给 runner
│           ↓
├─ agent-runner.sh 新结构:
│           ├─ resolve_provider()    读 dispatch 覆盖 / agent 默认 / global
│           ├─ source providers/${provider}.sh   加载 adapter
│           ├─ stdin 模式发 dispatch-preamble.md + spec
│           ├─ 跑 + 捕获 rc + log + git status diff
│           └─ adapter.evaluate_completion → done / failed / timeout / stale
│           ↓
├─ state/current.json 新增字段:
│   - agents.<a>.provider            (运行时实际使用的)
│   - agents.<a>.state 枚举扩:
│       claude-verifying | ready-for-human (新增)
│
├─ events.jsonl 每条加:
│   - provider: codex|claude|gemini
│   - phase:    dispatch|running|done|review|verify|gate-passed|gate-failed|bypass|failed
│
└─ 主 Claude (CLAUDE.md 三段式工作流):
    done-awaiting-review
       ↓ Karpathy A-F 审查
    claude-verifying ← 真打跑测试 + curl smoke + E2E
       ↓ 全过
    ready-for-human ← Stop hook 提醒 Lane 决策
```

## 3. 配置 Schema

`.aiagents/config.json`:

```json
{
  "default_provider": "codex",
  "agents": {
    "backend":  {
      "dir": "stock-be",
      "stack": "FastAPI",
      "provider": "codex",
      "test_cmd": "pytest",
      "lint_cmd": "ruff check .",
      "import_check": "python -c \"from app.main import app; print('OK')\"",
      "smoke_endpoints": [
        "http://127.0.0.1:8000/api/health",
        "http://127.0.0.1:8000/docs"
      ]
    },
    "frontend": {
      "dir": "stock-fe",
      "stack": "file://+React",
      "provider": "codex",
      "test_cmd": "",
      "lint_cmd": "",
      "build_cmd": "",
      "smoke_grep": [
        "grep -c 'fonts.googleapis' *.html",
        "grep -c 'src=\".*\\.jsx\"' *.html"
      ]
    }
  },
  "providers": {
    "codex":  {
      "bin": "codex",
      "args": "--dangerously-bypass-approvals-and-sandbox",
      "timeout": 1800,
      "subcommand": "exec",
      "stdin_supported": true
    },
    "claude": {
      "bin": "claude",
      "args": "--dangerously-skip-permissions",
      "timeout": 2400,
      "subcommand": "-p",
      "stdin_supported": true
    }
  },
  "workflow": { "max_retry": 3 },
  "paths": {
    "signals": ".aiagents/signals",
    "logs": ".aiagents/logs",
    "state": ".aiagents/state",
    "memory": ".aiagents/memory",
    "specs": "docs/ai-agents/specs",
    "reviews": "docs/ai-agents/reviews",
    "retrospectives": "docs/ai-agents/retrospectives",
    "prompts": ".aiagents/prompts",
    "runtime": ".aiagents/runtime"
  }
}
```

## 4. Adapter 接口契约

每个 provider `.sh` 脚本必须实现两个函数:

```bash
# templates/.aiagents/bin/providers/_template.sh

# 输入(env): PROVIDER_BIN PROVIDER_ARGS PROVIDER_SUBCMD WORK_ABS
# 输出 stdout 一行 cmd template
provider_build_cmd() { ... }

# 输入(env): RC LOG_FILE WORK_ABS GIT_STATUS_BEFORE GIT_STATUS_AFTER COMMIT_BEFORE COMMIT_AFTER
# 输出: done | failed | timeout | stale
# 默认实现见 _common.sh
provider_evaluate_completion() { ... }
```

**术语**: "commit advanced" = `git rev-parse HEAD` 前后变化(编码 agent 写了 commit);"working tree changed" = `git status --porcelain` 前后差异(有未 commit 的产出);"working tree clean" = `git status --porcelain` 输出为空。

### 4.1 Codex adapter(`providers/codex.sh`)

- `build_cmd`: `$BIN exec $ARGS -`(`-` 表示从 stdin 读 prompt)
- `evaluate_completion`:
  - rc=0 + commit advanced → `done`
  - rc=0 + working tree clean + 无 commit + log 含 `windows sandbox|permission denied` → `failed`(防 sandbox false-done,memory bugs.md 2026-05-02)
  - rc=124 → `timeout`
  - rc=1 + log 末尾 `Reconnecting|stream disconnect|502 Bad Gateway` + (commit advanced 或 working tree changed)→ `stale`(memory bugs.md 2026-05-07 R70)
  - rc=1 + working tree clean + 无 commit → `failed`(真 502 / 真错)
  - 其他 rc≠0 → `failed`

### 4.2 Claude Code adapter(`providers/claude.sh`)

- `build_cmd`: `$BIN -p $ARGS`(默认从 stdin 读 prompt)
- `evaluate_completion`:
  - rc=0 + commit advanced → `done`
  - rc=0 + working tree clean + 无 commit + log 含 `interactive prompt|waiting for input` → `failed`(防权限 prompt 卡死)
  - rc=124 → `timeout`
  - rc=1 + log 含 `429|529|rate.?limit|api.*overload` + 无 commit → `failed`(API 限流)
  - rc=1 + (commit advanced 或 working tree changed)→ `stale`(类 stream-disconnect)
  - 其他 rc≠0 → `failed`

### 4.3 共享 helper(`providers/_common.sh`)

- `send_prompt_via_stdin <cmd> <prompt_file>`: 用 `cat $prompt_file | $cmd` 发 prompt
- `default_evaluate_completion`: rc / git status / log 关键词的标准检查矩阵
- `record_provider_event <provider> <phase> <message>`: 写 events.jsonl 含 provider 字段

## 5. 派单 Prompt 组装

```
┌─ stdin to provider:
│  ├─ .aiagents/prompts/dispatch-preamble.md    (~300 字共享派单纪律)
│  ├─ .aiagents/prompts/project-preamble.md     (可选,项目自定义)
│  └─ docs/ai-agents/specs/<spec>.md            (实际派单合同)
│
└─ provider cwd: BACKEND_DIR / FRONTEND_DIR
   └─ Claude Code 自动 load 子目录 CLAUDE.md (角色边界)
```

### 5.1 `dispatch-preamble.md` 草稿

```markdown
# 派单纪律(由 ai-agents-kit 注入,跨 provider 共享)

你是被派单执行编码任务的 agent。请严格遵守:

1. **commit 纪律**: 禁用 `git add -A`,只 `git add <files>`。working tree 派单前已要求干净,你的 commit 应单一职责
2. **D Surgical**: 严禁等价 API 互换(如 `dataset.foo` ↔ `setAttribute('data-foo')`、`?.` ↔ `&&` 等)
3. **网络与浏览器**: 严禁自启浏览器(F12 由 Lane 人工验收)/ 调外部网络命令(curl 第三方 API / Playwright)
4. **失败上报**: spec 与现状有矛盾立即停下,写到 `.aiagents/runtime/<agent>-blocked.md`,不要盲改
5. **重写前 grep**: 整段重写 / 替换前先 `git show HEAD:<file> | sed -n '<a>,<b>p'` 看现状
6. **静态自检**: 在 commit 前自跑 spec § 自检矩阵全部 grep / wc / find 命令,粘到 commit message 末尾

派单合同正文从下一段开始:
---
```

## 6. 编码 agent 上下文隔离

### 6.1 三层隔离表

| 层 | 主 Claude | 编码 agent (codex / claude) |
|---|---|---|
| **进程** | Claude Code 主会话 | `codex exec ...` 或 `claude -p ...` 独立 child process |
| **CWD** | 项目根 | `BACKEND_DIR` / `FRONTEND_DIR` |
| **CLAUDE.md** | 项目根 `CLAUDE.md`(三 agent 协作 + 审查 rubric) | `<AGENT_DIR>/CLAUDE.md`(编码 agent 专用)— 仅 Claude Code 读 |
| **可读资源** | 全部 specs + reviews + retrospectives + memory | 仅当前派单的 `02 / 03 / 04` 之一 |
| **状态权限** | 写 review / 04 修复指令 | 写代码 + commit + 写 `runtime/<agent>-blocked.md` |

### 6.2 子目录 CLAUDE.md(install.sh 部署)

新模板 `templates/backend-CLAUDE.md` 装到 `${BACKEND_DIR}/CLAUDE.md`,内容包含:

- 角色边界硬约束(只读自己 spec,不读 reviews / retrospectives / memory / 项目根 CLAUDE.md / 对侧 agent 目录)
- 派单纪律(冗余覆盖 dispatch-preamble.md 的同源条款 — Claude Code 走 CLAUDE.md 路径,Codex 走 stdin 路径)
- 失败上报路径

`templates/frontend-CLAUDE.md` 同结构,禁忌项不同(file:// 内联 / 字体 CDN 镜像 / 命名空间冻结)。

### 6.3 主 CLAUDE.md 新增 § provider 同源审查纪律

在现有 `## ⛔ 审查触发 — 硬约束(别绕过)` 节后追加:

```markdown
## ⛔ provider 同源审查纪律(multi-provider 后)

历史教训: Codex 与主 Claude 异构,审查无"同根偏向"风险。
multi-provider 后编码 agent 可选 Claude Code(同模型不同会话),你和它对你而言仍是"外部 agent",规则不变:

- ❌ 严禁因"反正都是 Claude"放松审查 — Karpathy 6 项与 Codex 派单时同等严格
- ❌ 严禁用"它应该是这样想的"代替"git diff 实际证据"
- ❌ 严禁"顺手帮一下"自己改代码 — 编码 agent 失败仍走 04 修复 → 重派
- ✅ 你只看 state.json + events.jsonl + git diff + log + commit message
- ✅ 审查报告必须写明 `**Provider**: codex | claude` 字段(由你写,不依赖 events.jsonl)
```

### 6.4 主 Claude 工具权限硬封锁

`templates/.claude/settings.json` `permissions.deny` 加:

```json
{
  "permissions": {
    "deny": [
      "Edit(${BACKEND_DIR}/**)",
      "Edit(${FRONTEND_DIR}/**)",
      "Write(${BACKEND_DIR}/**)",
      "Write(${FRONTEND_DIR}/**)"
    ]
  }
}
```

**install.sh 占位替换**: install.sh / install.ps1 在写 `templates/.claude/settings.json` 到目标项目 `.claude/settings.json` 时,把 `${BACKEND_DIR}` `${FRONTEND_DIR}` 替换为 config.json 里的 `agents.backend.dir` `agents.frontend.dir`(绝对或相对路径均可,Claude Code 设置语法支持)。

**作用边界**: 主 Claude 试图改业务码会触发 permission prompt,Lane 显式 override 才能放行(防"顺手帮"诱因)。

**编码 agent 不受影响**: 编码 agent 在子目录 cwd 跑(BACKEND_DIR / FRONTEND_DIR),Claude Code CLI 用本会话的工作树根去找 settings.json — 子目录通常没有自己的 `.claude/settings.json`,会向上找到项目根的;但项目根 settings 的 `Edit(BACKEND_DIR/**)` deny 是 **glob 路径匹配**,编码 agent 在子目录里写 `./main.py`(相对自己 cwd 是 `BACKEND_DIR/main.py`)依然命中。**因此**编码 agent 必须用 `--dangerously-skip-permissions` 启动(adapter 默认 args 已含)绕过该 deny — 这正是 Q6 决策的原因。Codex 不读 settings.json,无影响。

## 7. Pre-Human Decision Gate(主 Claude 验证关卡)

### 7.1 三段式工作流

```
编码 agent 完成 → state=done-awaiting-review
       ↓ 主 Claude 走 Karpathy 6 项审查
state=claude-verifying ← 主 Claude 真打跑测试 + curl smoke + E2E
       ↓ 全过
state=ready-for-human ← Lane 拍板:收下 / 打回 / 推迟
       ↓
state=idle | running(打回 04) | 保留(推迟)
```

### 7.2 验证清单(Karpathy E 强化)

主 Claude 审查后必须连续跑下表所有项,任一失败 → 04 修复:

| 类别 | 命令(从 config.json 读) | 通过判据 |
|---|---|---|
| **后端测试** | `cd $BACKEND_DIR && $TEST_CMD` | exit 0 + 测试数 ≥ spec 验收 + 无 regression |
| **后端 lint** | `cd $BACKEND_DIR && $LINT_CMD` | exit 0 |
| **后端 import** | `$IMPORT_CHECK` | "OK" + 无 ImportError |
| **接口 smoke** | `curl -fsS $ENDPOINT` × N | 全 200 + 含 spec 要求字段 |
| **真 E2E** | `$E2E_CMD`(项目自定义) | exit 0 + 行数验证 + 数据形状 |
| **前端构建** | `cd $FRONTEND_DIR && $BUILD_CMD` | exit 0 + dist 产物存在 |
| **前端 lint** | `cd $FRONTEND_DIR && $LINT_CMD` | exit 0 |
| **前端 file:// smoke** | `agents.frontend.smoke_grep` 各项(从 config.json 读)+ spec § 自检矩阵补充 | 全部命中预期值 |

任一 stdout / stderr 含 `error|fail|exception|traceback|sandbox|forbidden|denied|connection refused`(case-insensitive)→ 主 Claude 必须解释,不能略过。

### 7.3 审查报告新增 § 真打验证

`docs/ai-agents/reviews/<agent>-review.md` 每轮增段:

```markdown
### § 真打验证(Pre-Human Decision Gate)

| 验证项 | 命令 | exit | 输出尾 5 行 | 通过 |
|---|---|---|---|---|
| BE 测试 | `pytest -q` | 0 | `... 86 passed in 12.3s` | ✅ |
| BE lint | `ruff check .` | 0 | `All checks passed!` | ✅ |
| BE import | `python -c "from app.main import app; print('OK')"` | 0 | OK | ✅ |
| 接口 smoke | `curl ... /api/market/dashboard?days=70` | 0 | `{"breadth":...}` | ✅ |
| 真 E2E | `POST .../api/sync/finance` + `psql -c "SELECT count..."` | 0 | rows=5512 | ✅ |
| FE smoke | `grep -c 'fonts.googleapis' *.html` | 0 | 0 | ✅ |

**全部 ✅ → state 推进 ready-for-human**
```

报告未含此段 = 报告无效。

### 7.4 应急 bypass

```
/release-without-verify backend "急上 reason"
    ↓ state 直接 done-awaiting-review → ready-for-human
    ↓ events.jsonl append {phase:"verify-bypassed",reason:"...",by:"lane"}
    ↓ memory bugs.md 自动追加破例记录
```

默认 OFF,Lane 主动敲。每次破例进 memory(给未来 Claude 留痕)。

### 7.5 Provider 切换的任务一致性 (Handover 机制)

**问题**: 编码 agent 是无状态的(每次派单 fresh process)。当 claude 跑了 60% 因 token 耗尽切到 codex,如果不处理,codex 看到的是改了一半的工作树,可能从头重做(违反 D Surgical 且浪费时间)。

**机制**:

```
claude 失败 → 主 Claude 决定换家 → 写 runtime/<agent>-handover.md → 调 /dispatch --provider codex
                                                                                ↓
                                                      runner 检测 handover.md 存在
                                                                                ↓
                                                      stdin: preamble + handover + spec
                                                                                ↓
                                                      codex 读 handover 知道"我是续做"
                                                                                ↓
                                                      按现状 + 验收 ❌ 项推进,不重写 ✅ 项
```

**`runtime/<agent>-handover.md` 模板**(由主 Claude 在切换前填写):

```markdown
# Handover: <agent> 接续派单 (provider <prev> → <new>)

**触发**: 主 Claude 决定换 provider,前一家 <prev> 失败 (<failure_reason>)

## 前一轮已落

- 自 <baseline_sha> 起的 commits:
  - <sha1> <subject>
  - <sha2> <subject>
- 未 commit 改动:
  - <git status --short 输出>

## Spec 验收清单逐项状态

(主 Claude 跑 spec § 自检 grep 矩阵后填)

- ✅ §1 字段 X 已实现 (file.py:42)
- ✅ §2 endpoint Y 已实现 (api/x.py:13)
- ❌ §3 测试覆盖 Z (pytest tests/test_z.py 仍 NotImplementedError)
- ❌ §4 lint 修一处 ruff E501

## 续做要求(硬约束)

1. 基于当前 working tree 状态续做,**不重写** ✅ 状态的模块
2. 优先补齐 ❌ 状态的验收点(按上序逐项推进)
3. 如发现前一轮某 ✅ 模块写错,单独 commit 修(commit message 含 "fix prev round")
4. commit 不覆盖前一轮历史 — 新 commit 在 HEAD 上叠加(禁 git reset / amend / push -f)

## 原 spec 在下一段
---
```

**主 Claude 写 handover 的最低要求**:
- ✅ 列前一家 commits + 未提交改动(`git log <baseline>..HEAD` + `git status --porcelain`)
- ✅ 跑 spec § 自检 grep 矩阵填 ✅/❌
- ✅ 验收 ❌ 项至少一句话说明"还差什么"
- ❌ 不写 handover 直接 retry → 编码 agent 没接续依据可能重做(memory 钉死)

**子目录 CLAUDE.md 新增条款**(部署模板时一并写入):

```markdown
## 接续派单(如有)

如果你读到 `.aiagents/runtime/<agent>-handover.md`,**先读它再读 spec** — 这是接续派单:
- 前一家 provider 已部分完成,你是续做
- handover 列出 ✅/❌ 验收清单 — 只做 ❌ 项
- 不重写 ✅ 项,即便你觉得能写得更好(D Surgical 硬约束)
- 续做完成时 commit 不覆盖前一轮历史
```

**`/retry-other-provider <agent>` slash 命令**(半自动 — 主 Claude 智能填):
- agentctl 子命令读 events.jsonl 末尾上次该 agent 用的 provider
- 从 config providers 找另一家
- 在 runtime/ 创建 handover.md **骨架**(prefilled 前一家 + commits + git status,空 ✅/❌ 段)
- **不直接派** — 提示主 Claude:"已生成 handover 骨架,请填 ✅/❌ 后调 /dispatch-<agent> --provider <other>"
- 主 Claude 跑 spec § grep 矩阵填 ✅/❌ → 调 dispatch
- runner 检测 handover.md 存在 → prepend 到 PROMPT_FILE,新 agent 读

**为什么不全自动**: 验收 ✅/❌ 评估需理解 spec 语义(每条验收点对应哪些 grep / 测试),主 Claude 智能层胜任,Bash 自动化容易漏判。Lane 一键 `/retry-other-provider` 触发主 Claude 走流程足够。

**handover.md 生命周期**:
- 主 Claude 写 → runner prepend → 编码 agent 读
- 派单成功落 commit → 主 Claude review 通过 → handover.md 移到 `runtime/archive/<timestamp>-<agent>-handover.md`(保留留痕)
- agentctl 自动 archive,不让 stale handover 影响下一阶段派单

### 7.6 主 Claude 运维 vs 代码编辑边界

memory `patterns.md 2026-05-03 主 Claude 自动 E2E 收尾` + `bugs.md 2026-05-04 P2.2.b R26` 已沉淀:

- ✅ 运维操作主 Claude 可做: kill / 起 uvicorn / 跑 pytest / 跑 ruff / curl smoke / 跑 coldstart / 启 http.server
- ❌ 代码编辑主 Claude 严禁: Edit / Write 业务文件 — 由 settings.json deny 强制

## 8. 文件改动清单

### 8.1 新建(7 个)

| 路径 | 用途 |
|---|---|
| `templates/.aiagents/bin/providers/codex.sh` | Codex adapter |
| `templates/.aiagents/bin/providers/claude.sh` | Claude Code adapter |
| `templates/.aiagents/bin/providers/_common.sh` | 共享 stdin 发 prompt + 默认 evaluate_completion |
| `templates/.aiagents/prompts/dispatch-preamble.md` | 跨 provider 共享派单纪律 |
| `templates/backend-CLAUDE.md` | 编码 agent 后端专用 CLAUDE.md(装到 BACKEND_DIR) |
| `templates/frontend-CLAUDE.md` | 编码 agent 前端专用 CLAUDE.md(装到 FRONTEND_DIR) |
| `docs/designs/2026-05-09-multi-provider-design.md` | 本文件 |

### 8.2 改造(12 个)+ 1 新增 slash 命令

| 路径 | 类型 | 改动 |
|---|---|---|
| `templates/.aiagents/bin/agent-runner.sh` | 改造 | 引入 provider 解析 + adapter 调用 + stdin 发 prompt + 用新 evaluate_completion |
| `templates/.aiagents/bin/agentctl.sh` | 改造 | `dispatch` 子命令支持 `--provider <name>` `--timeout <s>`;`status` 输出加 Provider 列;新增 `release-without-verify` 子命令 |
| `templates/.aiagents/bin/agentctl.ps1` | 改造 | PowerShell 等价改造 |
| `templates/.aiagents/bin/watch-agent.sh` | 改造 | 透传 provider 元数据到 runner |
| `templates/.claude/commands/dispatch-backend.md` | 改造 | 加 `$ARGUMENTS` 解析 → 透 `--provider` `--timeout` |
| `templates/.claude/commands/dispatch-frontend.md` | 改造 | 同上 |
| `templates/.claude/commands/bugfix-backend.md` | 改造 | 同上 |
| `templates/.claude/commands/bugfix-frontend.md` | 改造 | 同上 |
| `templates/.claude/commands/release-without-verify.md` | **新增** | bypass 闸门 slash 命令 |
| `templates/.claude/commands/retry-other-provider.md` | **新增** | provider 切换接续 slash 命令 |
| `templates/.claude/settings.json` | 改造 | `permissions.deny` 加业务目录 Edit / Write 锁 |
| `templates/CLAUDE.md` | 改造 | 加 § provider 同源审查纪律 + § Pre-Human Decision Gate |
| `install.sh` | 改造 | schema 升级 + `--migrate-v1` 兼容 + 部署子目录 CLAUDE.md + smoke test |
| `install.ps1` | 改造 | 同上(Windows 路径) |

### 8.3 删除(0 个)

无 — v1 旧字段 `codex.bin` `codex.args` 在 install.sh 内部映射到 `providers.codex.*`,但 config.json 重写后只保留新 schema 字段。`agents.conf` 仍作 read-only fallback 保留。

## 9. v1 / v2 兼容

### 9.1 检测路径

```
install.sh 启动时:
  if .aiagents/state/ 存在 + .aiagents/config.json 含 providers.* 块 → v3 (multi-provider) — 跳过迁移
  if .aiagents/state/ 存在 + .aiagents/config.json 仅含 codex.* → v2 (current) — 升级到 v3
  if docs/superpowers/specs/ 存在 + .aiagents/state/ 不存在 → v1 — 错误提示用 --migrate-v1
  if 上述都不存在 → 全新安装
```

### 9.2 v2 → v3 迁移逻辑(自动,跑 install.sh 触发)

1. 读旧 `config.json`:
   - `codex.bin` → `providers.codex.bin`
   - `codex.args` → `providers.codex.args`
   - `codex.timeout_seconds` → `providers.codex.timeout`
   - `backend.dir` → `agents.backend.dir`
   - `backend.stack` → `agents.backend.stack`
   - 类似 frontend.*
2. 注入 `agents.{backend,frontend}.provider = "codex"`(行为零变化)
3. 注入 `default_provider = "codex"`
4. 注入 `providers.claude` 默认块(用户想用时只需改 `agents.X.provider`)
5. 注入 `agents.{backend,frontend}.test_cmd / lint_cmd / smoke_endpoints` — 从旧 `agents.conf` `BACKEND_TEST_CMD` 等读,缺失则空
6. 部署 `BACKEND_DIR/CLAUDE.md` `FRONTEND_DIR/CLAUDE.md`(若已存在 → 询问"覆盖 / 跳过 / 写 .new 让我手工合并",`--migrate-v1` 默认跳过)
7. 状态扩展是向后兼容的 — 老 `done-awaiting-review` 仍合法,新枚举值 `claude-verifying` `ready-for-human` 在下一次 dispatch 自动出现
8. 写 `MIGRATED.md` 记录本次迁移做了什么(子目录 CLAUDE.md 用途 / 新 slash 命令 / state 枚举扩展)

### 9.3 choseStock 实战升级路径

1. `cd /d/dev/ai/workspace/choseStock && bash <ai-agents-kit>/install.sh --migrate-v1` 二次跑
2. 验证 `.aiagents/config.json` 含 `providers.{codex,claude}` 块,`agents.backend.provider == "codex"`
3. 验证 `stock-be/CLAUDE.md` `stock-fe/CLAUDE.md` 已部署或正确跳过
4. 第一次 dispatch backend 用 codex(默认):全程跑通 verify gate,验 ready-for-human
5. 第二次 dispatch frontend 用 claude(`/dispatch-frontend --provider claude`):验 multi-provider + verify gate 同时工作
6. 实战验证后写到 memory bugs.md(切换 / 升级第一次必盯模式)

## 10. 验证 / Smoke Test

落盘后跑(install.sh 末尾自动 + 手工再跑一次):

| # | 测试 | 预期 |
|---|---|---|
| 1 | `agentctl.sh dispatch backend --provider codex` 占位 spec(5 行 echo)| 5s 内退出,git status clean,events.jsonl 末尾 phase=done provider=codex |
| 2 | `agentctl.sh dispatch backend --provider claude` 同 spec | 同 ✅,provider=claude |
| 3 | `agentctl.sh dispatch backend`(走默认) | 用 agents.backend.provider 配置值 |
| 4 | `agentctl.sh dispatch backend --provider gemini` | 优雅 fail "未配置 gemini provider, providers 块只有 codex/claude" |
| 5 | 派一个真 spec(如 `02-后端编码.md` 含 1 个简单 endpoint),完整走完三段式 | done-awaiting-review → claude-verifying → ready-for-human;Stop hook 触发 |
| 6 | 派一个会失败 verify 的 spec(故意写错字段) | claude-verifying → 04-Bug修复 → 重派 |
| 7 | `/release-without-verify backend "test"` | done-awaiting-review → ready-for-human;memory bugs.md 自动追加 |
| 8 | 主 Claude 试图 Edit `stock-be/main.py` | settings.json deny 拦截,触发 permission prompt |

## 11. 风险与应对

| 风险 | 来源 | 应对 |
|---|---|---|
| Claude Code stdin 模式行为不同 / 不支持 | 实测可能踩坑 | install.sh 跑 smoke test 验,失败给清晰错误信息 |
| `--migrate-v1` 二次跑时 `choseStock/stock-be/CLAUDE.md` 已存在(第一次 v1→v2 迁移时未部署) | 现状 choseStock 没部署过 | install.sh 默认跳过 + 提示用户手工 review |
| Lane 第一次切 Claude Code 时遇上 Anthropic API 429 | API 限流 | adapter `evaluate_completion` 把 `429|529` 关键词判 failed,events.jsonl 留诊断,Lane 看到自然换回 codex |
| 两个 Claude 实例并发改 events.jsonl | 主 Claude + 编码 Claude 同时跑 | 当前 watcher append 模式无锁,用 jsonl 行级 atomic 已足够;若并发量上升再加文件锁 |
| 主 Claude 无视 settings.json deny 强行改业务码 | 模型可能"我急用绕一下" | settings.json deny 是 Claude Code CLI 强制层,绕不过;memory bugs.md 已记入 2026-04-28"主 Claude 误以为 Codex 没交付直接动手"血泪教训 |
| Verify gate 跑测试时 PG 连不上 | TEST_DATABASE_URL 没配 | 主 Claude 报告里写"测试 skip 数 ≥ N → 04 修复要求开 TEST_DATABASE_URL",memory patterns.md 2026-05-03 已沉淀此模式 |

## 12. _DEFERRED(待考虑)

### 12.1 桌宠 / 状态提醒(2026-05-09 用户提出,留下次 brainstorm)

**痛点**: Lane 主 Claude 等人工决策时无桌面提醒,容易错过决策窗口。

**三档方案**:

| 档 | 形态 | 开发量 | 适合 |
|---|---|---|---|
| A | 系统托盘 + 气泡通知(Win PowerShell + `NotifyIcon`) | 1-2 天 | 解"看不到提醒"核心痛点 |
| B | 浏览器 always-on-top HUD(localhost SSE + 浮窗 HTML) | 3-5 天 | 浮动状态条 + 点击交互 |
| C | Electron / Tauri 桌宠(常驻半透明 + 拖动 + 多状态动画) | 1-2 周 + 维护 | 真"桌宠"陪伴感 |

**推荐**: 下次先做 A 档(1-2 天解痛点),B/C 等用一段时间再决定。

**与 multi-provider 解耦**: `state/current.json` `events.jsonl` 是稳定接口,UI 客户端 polling 即可,不动 watcher / runner / adapter。multi-provider 引入的 `claude-verifying` `ready-for-human` 状态 UI 直接受益。

### 12.2 Gemini adapter 实装

第一版只留 `providers/gemini.sh` 占位,等下游有项目要用时再实装(预计 0.5-1 天,沿 codex/claude 模板扩)。

### 12.3 token / API key 隔离

`providers.claude.env` 字段(`ANTHROPIC_API_KEY` `CLAUDE_CODE_USE_BEDROCK` 等)— 让编码 Claude 用与主 Claude 不同的 key / 后端,避免计费冲突。本期默认共用,下版升级。

### 12.4 watcher 信号 race 修复

memory `bugs.md 2026-05-06 R55-R59` Codex apply_patch 滞后 commit,导致 wait expired 误判。本期 multi-provider 不修(复用现有 stale-recovery SOP),独立阶段评估。

### 12.5 verify gate auto-bypass 阈值

某些纯文档 / 纯样式改动(如 markdown 改 / tokens.css 调色)走 verify gate 多余。下版考虑加"diff 仅命中白名单文件 → 自动 bypass"开关,本期不实施。

## 13. 工时估算

| 阶段 | 内容 | 估时 |
|---|---|---|
| Plan 落地 | spec → writing-plans 出可执行步骤 | 0.5 天 |
| Adapter 实装 + agent-runner 改造 | codex.sh / claude.sh / _common.sh / runner | 1 天 |
| schema + install.sh + 迁移 | config.json / install.sh / install.ps1 / `--migrate-v1` 路径 | 1 天 |
| Slash 命令 + agentctl + watcher | 4 dispatch-* + release-without-verify + agentctl | 0.5 天 |
| 子目录 CLAUDE.md + 主 CLAUDE.md + settings.json deny | prompt + 模板 | 0.5 天 |
| Verify gate 实装(主 Claude 端) | 主 CLAUDE.md 写工作流 + 报告模板 | 0.5 天 |
| Smoke test + choseStock 实战 | 8 项 smoke + 2 次真派单(codex/claude 各一次) | 1 天 |
| 文档 + memory 写回 | docs/ai-agents/README.md 升级 + memory 沉淀 | 0.5 天 |
| **合计** | | **5.5 天** |
