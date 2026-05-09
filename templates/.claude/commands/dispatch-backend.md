---
description: 派发后端任务给 Codex-Backend,自动等待完成并直接审查(无需用户再次发消息)
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

**前置检查**(逐项核对,任何一项不满足则终止并告知用户):
1. `docs/ai-agents/specs/02-后端编码.md` 存在(或 `02-backend.md`)
2. 该文件里每个任务项都有明确的验收标准
3. 用户已确认 02 内容
4. 已读 `.aiagents/memory/global/patterns.md` 和 `.aiagents/memory/global/bugs.md`(若已有相关条目,要在派发前提醒用户复用经验或避免坑)

---

**用法**:
- `/dispatch-backend` — 用 agent 默认 provider
- `/dispatch-backend --provider claude` — 这次用 Claude Code
- `/dispatch-backend --provider codex --timeout 3600` — 切 codex + 自定义超时

**第一步 — 派发**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" dispatch $ARGUMENTS backend`

如果命令返回非零(常见: `--provider X` 中 X 不在 config.json `providers` 块里),把错误原样展示给用户并终止。

---

**第二步 — 自动等待 Codex 完成(主动轮询,不需要用户再说话)**:
`bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" wait backend`

最长等待 9 分钟;信号一出现立即退出。

---

**第三步 — 根据退出码自动处理(不需要等用户发消息)**:

| 退出码 | 含义 | 你的动作 |
|--------|------|----------|
| 0 | `backend_done` — Codex 完成 | 立即按 CLAUDE.md Karpathy rubric 开始审查 |
| 1 | `backend_failed` — Codex 失败 | 读 `.aiagents/state/events.jsonl` 末尾 + `.aiagents/logs/be_<today>.log` 末尾, 生成 `docs/ai-agents/specs/04-Bug修复-backend.md`,问用户是否 `/bugfix-backend` |
| 2 | `backend_timeout` — Codex 卡死 | 告知用户检查 watcher 终端网络状态,建议重新 `/dispatch-backend` |
| 3 | 9 分钟内无信号 | 告知用户 Codex 仍在运行(长任务正常),Stop hook 在下次消息时兜底 |

**派发后的标准应答**:
> 后端任务已派发,正在等待 Codex-Backend 完成...
