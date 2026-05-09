---
description: 派发前端任务给 Codex-Frontend,自动等待完成并直接审查(无需用户再次发消息)
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**:
1. `docs/ai-agents/specs/03-前端编码.md` 存在(或 `03-frontend.md`)且有明确验收标准
2. 如果前端依赖后端 API,后端必须已审查通过(`docs/ai-agents/reviews/backend-review.md` 最新一轮结论 ✅)。未通过则终止
3. 用户已确认 03 内容
4. 已读 memory(同 dispatch-backend)

---

**第一步 — 派发**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch frontend`

---

**第二步 — 自动等待 Codex 完成**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait frontend`

---

**第三步 — 根据退出码自动处理**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | `frontend_done` — Codex 完成 | 立即按 CLAUDE.md Karpathy rubric 开始审查 |
| 1 | `frontend_failed` — Codex 失败 | 读事件 + 日志,生成 `04-Bug修复-frontend.md`,问用户是否 `/bugfix-frontend` |
| 2 | `frontend_timeout` — Codex 卡死 | 告知用户检查 watcher 终端网络状态,建议重新 `/dispatch-frontend` |
| 3 | 9 分钟内无信号 | 告知用户 Codex 仍在运行,Stop hook 兜底 |
