---
description: 派发后端修复任务,自动等待完成并直接再审查
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**:
1. `docs/ai-agents/specs/04-Bug修复-backend.md` 存在(或 `04-bugfix-backend.md`)
2. 该文件必须是本轮审查的最新版(由 `docs/ai-agents/reviews/backend-review.md` 最新一轮失败项生成)
3. 修复指令要具体到文件和行号,引用 Karpathy 原则分类(A/B/C/D/E/F)

---

**用法**:
- `/bugfix-backend` — 用 agent 默认 provider
- `/bugfix-backend --provider claude` — 这次用 Claude Code 修
- `/bugfix-backend --provider codex --timeout 3600` — 切 codex + 自定义超时

**第一步 — 派发修复**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch $ARGUMENTS bugfix-backend`

---

**第二步 — 自动等待编码 agent 修复完成**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait backend`

---

**第三步 — 根据退出码自动处理**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | 修复完成 | 立即按 Karpathy rubric 再次审查;通过则推进,仍失败则再生成修复单(上限 MAX_RETRY 次) |
| 1 | 修复失败 | 读失败原因,判断是否可再次修复,已达 MAX_RETRY 则告知用户人工介入 |
| 2 | 编码 agent 卡死 | 告知用户检查网络,此次超时不计入重试次数 |
| 3 | 9 分钟内无信号 | **启动 `/loop` 自动轮询**: 调 Skill tool `skill=loop, args="5m /status"`, 告知 Lane "已启动 5min 自动轮询,完成会自动审查"。loop 每 tick 检测 state, `done-awaiting-review` 时审查 + 停 loop。fallback: Lane 手动敲 `/loop 5m /status`。 |

**执行后标准应答**:
> 后端修复任务已派发,正在等待编码 agent 完成...
