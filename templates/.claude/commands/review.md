---
description: 手动触发代码审查(兜底,通常 Stop hook 会自动触发)
---

立即按 CLAUDE.md 的 Karpathy 审查 rubric 对最近一次 编码 agent 交付物进行审查。

步骤:
1. **判断审查对象**: 先 `/status` 看 `.aiagents/state/current.json` 的 `backend.state` / `frontend.state`,只有 `done-awaiting-review` 才允许审查。如用户指明 `/review backend` 或 `/review frontend`,以用户指定为准
2. 读 `.aiagents/state/events.jsonl` 末尾 30 条,确认 编码 agent 真的执行过(有 running → done 事件链)
3. 读对应 `.aiagents/logs/{be|fe}_<today>.log` 的尾部 100 行
4. 读对应 `<BACKEND_DIR>` 或 `<FRONTEND_DIR>` 的 `git diff`(自最近一次 dispatch 以来)
5. 对照 `docs/ai-agents/specs/02-后端编码.md` 或 `03-前端编码.md` 的每条验收标准
6. 逐项走 Karpathy 6 项审查(A 执行验证 / B Think / C Simplicity / D Surgical / E Goal-Driven / F Sanity)
7. 追加审查段落到 `docs/ai-agents/reviews/backend-review.md` 或 `frontend-review.md`
8. 如果失败,生成 `docs/ai-agents/specs/04-Bug修复-{backend|frontend}.md` 并询问用户是否执行 `/bugfix-*`
