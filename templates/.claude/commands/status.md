---
description: 查看三个 agent 当前状态(state/current.json + 最新日志尾部)
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

立即执行(使用绝对路径,防止 CWD 偏移导致脚本找不到):
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" status`

读完输出后,向用户用一段话摘要:
- 后端当前是"空闲 / 队列中 / 进行中 / 已完成待审查 / 失败 / 超时"哪一种
- 前端同上
- worker 进程状态(running / stopped / stale)
- 如果有失败项,指出日志里最可疑的几行

**重要**:`state.<agent>.state == "done-awaiting-review"` 才是合法的审查触发条件。**不要**因为日志里看到"completed"就开始审查。
