---
description: 派发前端修复任务,自动等待完成并直接再审查
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**同 bugfix-backend,只是把 backend 换成 frontend。

---

**用法**:
- `/bugfix-frontend` — 用 agent 默认 provider
- `/bugfix-frontend --provider claude` — 这次用 Claude Code 修
- `/bugfix-frontend --provider codex --timeout 3600` — 切 codex + 自定义超时

**第一步 — 派发修复**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch $ARGUMENTS bugfix-frontend`

---

**第二步 — 自动等待编码 agent 修复完成**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait frontend`

---

**第三步 — 根据退出码自动处理**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | 修复完成 | 立即按 Karpathy rubric 再次审查 |
| 1 | 修复失败 | 读失败原因,判断是否可再次修复,达 MAX_RETRY 则告知用户人工介入 |
| 2 | 编码 agent 卡死 | 告知用户检查网络,不计入重试次数 |
| 3 | 9 分钟内无信号 | **启动 `/loop` 自动轮询**: 调 Skill tool `skill=loop, args="5m /status"`, 告知 Lane "已启动 5min 自动轮询"。loop tick 检测到 `done-awaiting-review` 自动审查 + 停 loop。fallback: Lane 手动敲 `/loop 5m /status`。 |
