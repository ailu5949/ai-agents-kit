---
description: 派发后端任务给 Backend 编码 agent,自动等待完成并直接审查(无需用户再次发消息)
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**(逐项核对,任何一项不满足则终止并告知用户):
1. `docs/ai-agents/specs/02-后端编码.md` 存在(或 `02-backend.md`)
2. 该文件里每个任务项都有明确的验收标准
3. 用户已确认 02 内容
4. 已读 `.aiagents/memory/global/patterns.md` 和 `.aiagents/memory/global/bugs.md`(若已有相关条目,要在派发前提醒用户复用经验或避免坑)

---

**用法**:
- `/dispatch-backend` — 用 agent 默认 provider + 默认 model
- `/dispatch-backend --provider claude` — 这次用 Claude Code (model 走配置默认)
- `/dispatch-backend --provider claude --model sonnet` — Claude Code + sonnet 模型
- `/dispatch-backend --provider claude --model claude-sonnet-4-5` — Claude Code + 完整模型名
- `/dispatch-backend --model haiku` — 当前 provider 改用 haiku (轻量任务省钱)
- `/dispatch-backend --provider codex --timeout 3600` — 切 codex + 自定义超时

**model 优先级**: `--model` flag > `agents.<a>.model`(config.json) > `providers.<p>.model`(config.json) > 空(让 CLI 自己选默认)。

**model 值直接传给 CLI**(kit 不改写,v3.4.3):

| 你写的值 | 行为 |
|---|---|
| `sonnet` / `opus` / `haiku` | claude CLI 内建 alias,**自动解析到最新版本**(现在 sonnet=4.6 / opus=4.6)。将来出 4.7 自动跟进,无需改配置 |
| `claude-sonnet-4-6`(完整名) | 锁定具体版本,CLI 原样接受 |
| `gpt-5` / `gpt-5.5` / `gpt-5-codex`(codex) | 直接传 codex CLI |

> ⚠️ kit **不再硬编码** `sonnet→claude-sonnet-4-6`(v3.4.2 的错误设计)。`sonnet` 交给 claude CLI 解析,永远指向最新 — 这正是"sonnet 默认 4.6"想要的效果。

**自定义 alias**(可选,仅当想锁定某个历史快照): 编辑 `.aiagents/config.json`:
```json
{
  "providers": {
    "claude": {
      "model_aliases": {
        "stable": "claude-sonnet-4-5-20250929"
      }
    }
  }
}
```
之后 `--model stable` 展开成那个固定快照(不随 CLI alias 漂移)。

**第一步 — 派发**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch $ARGUMENTS backend`

如果命令返回非零(常见: `--provider X` 中 X 不在 config.json `providers` 块里),把错误原样展示给用户并终止。

---

**第二步 — 自动等待编码 agent 完成(主动轮询,不需要用户再说话)**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait backend`

最长等待 9 分钟;信号一出现立即退出。

---

**第三步 — 根据退出码自动处理(不需要等用户发消息)**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | `backend_done` — 编码 agent 完成 | 立即按 CLAUDE.md Karpathy rubric 开始审查 |
| 1 | `backend_failed` — 编码 agent 失败 | 读 `.aiagents/state/events.jsonl` 末尾 + `.aiagents/logs/be_<today>.log` 末尾, 生成 `docs/ai-agents/specs/04-Bug修复-backend.md`,问用户是否 `/bugfix-backend` |
| 2 | `backend_timeout` — 编码 agent 卡死 | 告知用户检查 watcher 终端网络状态,建议重新 `/dispatch-backend` |
| 3 | 9 分钟内无信号 | **启动定时轮询**(见下方"第四步")— 不要简单告知"等下次消息" |

---

**第四步(仅当退出码 = 3 时执行)— 启动 `/loop` 自动轮询**:

编码 agent 是长任务(超过 9 分钟 wait 上限)。立即调用 `loop` skill 启动后台轮询,主 Claude 自我唤醒检查状态:

1. **调用 Skill tool**:
   - `skill`: `loop`
   - `args`: `5m /status`
2. **告知 Lane**:
   > 后端任务还在跑(超 9 分钟未完成)。已启动 5 分钟自动轮询: 每 5min 跑 `/status` 检查状态,检测到 `done-awaiting-review` 后 Stop hook 注入,我会自动启动 Karpathy 审查并推到 `ready-for-human`。Lane 可以离开,完成时桌面 toast 通知。
3. **轮询期间行为**(loop 每次唤醒主 Claude):
   - `state.backend.state == "running"` 或 `queued` → 啥也不做,等下个 5min tick
   - `state.backend.state == "done-awaiting-review"` → 立即按 CLAUDE.md Karpathy rubric 审查,审查完进 Pre-Human Decision Gate 真打验证,推到 `ready-for-human` 后**主动调 `loop` skill 自身停止**(或调用 `TaskStop`)
   - `state.backend.state == "failed"` → 走 04 修复流程,**先停 loop**
   - `state.backend.state == "timeout"` → 走 Timeout Triage SOP,**先停 loop**

**降级 fallback**: 若 `loop` skill 不可用(报错),告知 Lane:
> 请敲 `/loop 5m /status` 让我每 5 分钟自动检查后端状态。
> (Lane 显式开 loop 等价于 skill 调用,但需要 Lane 手动敲一次)

---

**派发后的标准应答**:
> 后端任务已派发,正在等待 Backend 编码 agent 完成...
