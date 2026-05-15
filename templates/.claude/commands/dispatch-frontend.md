---
description: 派发前端任务给 Frontend 编码 agent,自动等待完成并直接审查(无需用户再次发消息)
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**:
1. `docs/ai-agents/specs/03-前端编码.md` 存在(或 `03-frontend.md`)且有明确验收标准
2. 如果前端依赖后端 API,后端必须已审查通过(`docs/ai-agents/reviews/backend-review.md` 最新一轮结论 ✅)。未通过则终止
3. 用户已确认 03 内容
4. 已读 memory(同 dispatch-backend)

---

**用法**:
- `/dispatch-frontend` — 用 agent 默认 provider + 默认 model
- `/dispatch-frontend --provider claude --model sonnet` — Claude Code + sonnet 模型
- `/dispatch-frontend --model haiku` — 当前 provider 改用 haiku (前端任务轻量省钱)
- `/dispatch-frontend --provider codex --timeout 3600` — 切 codex + 自定义超时

**第一步 — 派发**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch $ARGUMENTS frontend`

---

**第二步 — 自动等待编码 agent 完成**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait frontend`

---

**第三步 — 根据退出码自动处理**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | `frontend_done` — 编码 agent 完成 | 立即按 CLAUDE.md Karpathy rubric 开始审查 |
| 1 | `frontend_failed` — 编码 agent 失败 | 读事件 + 日志,生成 `04-Bug修复-frontend.md`,问用户是否 `/bugfix-frontend` |
| 2 | `frontend_timeout` — 编码 agent 卡死 | 告知用户检查 watcher 终端网络状态,建议重新 `/dispatch-frontend` |
| 3 | 9 分钟内无信号 | **启动 `/loop` 自动轮询**(见下方,等价 dispatch-backend.md 第四步)|

---

**第四步(仅当退出码 = 3 时执行)— 启动 `/loop` 自动轮询**:

前端任务还在跑(超过 9 分钟 wait 上限)。立即调用 `loop` skill 启动后台轮询:

1. **调用 Skill tool**: `skill=loop`, `args="5m /status"`
2. **告知 Lane**:
   > 前端任务还在跑(超 9 分钟未完成)。已启动 5 分钟自动轮询: 每 5min 跑 `/status`,检测到 `done-awaiting-review` 后自动审查并推到 `ready-for-human`。Lane 可以离开。
3. **每个 loop tick 行为**:
   - `running` / `queued` → 等下个 tick
   - `done-awaiting-review` → 立即按 Karpathy rubric 审查 + verify gate → `ready-for-human`,**主动停 loop**
   - `failed` → 走 04 修复流程,**先停 loop**
   - `timeout` → 走 Timeout Triage SOP,**先停 loop**

**降级 fallback**: 若 `loop` skill 不可用,告知 Lane:
> 请敲 `/loop 5m /status` 让我每 5 分钟自动检查前端状态。
