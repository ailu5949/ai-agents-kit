---
description: 派发前端修复任务,自动等待完成并直接再审查
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**同 bugfix-backend,只是把 backend 换成 frontend。

---

**第一步 — 派发修复**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch bugfix-frontend`

---

**第二步 — 自动等待 Codex 修复完成**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait frontend`

---

**第三步 — 根据退出码自动处理**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | 修复完成 | 立即按 Karpathy rubric 再次审查 |
| 1 | 修复失败 | 读失败原因,判断是否可再次修复,达 MAX_RETRY 则告知用户人工介入 |
| 2 | Codex 卡死 | 告知用户检查网络,不计入重试次数 |
| 3 | 无信号 | Stop hook 兜底 |
