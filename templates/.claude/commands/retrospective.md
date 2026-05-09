---
description: 完成一个完整需求后的复盘 + 写入记忆
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(git diff:*), Bash(git log:*)
---

执行一次完整复盘:

1. **汇总本轮工作**:
   - 读 `docs/ai-agents/specs/01-需求.md` (需求边界)
   - 读 `docs/ai-agents/reviews/backend-review.md`、`docs/ai-agents/reviews/frontend-review.md` 最新一轮结论
   - 读 `.aiagents/state/events.jsonl` 末尾 50 条事件,提炼时间线

2. **从 git 提炼实质改动**:
   - `git log --oneline -20`
   - `git diff <baseline>..HEAD --stat`(baseline 取本需求开始前的 commit)

3. **写复盘报告**到 `docs/ai-agents/retrospectives/$(date +%Y-%m-%d)-retro.md`,包含:
   - 需求摘要(1 段)
   - 后端实现要点(3-5 条)
   - 前端实现要点(3-5 条)
   - 审查发现的 bug 和修复轮次
   - **成功模式**(可复用的)和**失败模式**(要避免的)
   - **用户特别强调的偏好或约束**(写入 projects/context.md)

4. **回写记忆**:
   - 每条成功模式 → `bash .aiagents/bin/agentctl.sh memory "<经验文本>"`(写入 global/patterns.md)
   - 失败模式 → 直接编辑 `.aiagents/memory/global/bugs.md` 追加段落
   - 项目决策 → 直接编辑 `.aiagents/memory/projects/context.md`
   - 产品想法(如果用户提到) → 直接编辑 `.aiagents/memory/ideas/product-ideas.md`

5. **告诉用户**复盘已生成,以及记忆系统更新了哪些条目。

> 提示:复盘是 ai-agents-kit 跨项目复用能力的核心。下次新项目启动时,Claude 会先读 patterns.md 和 bugs.md,避免从零开始。
