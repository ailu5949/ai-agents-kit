---
description: 生成会话交接文档 — Token 不足需切换模型前运行
---

**用途**: 当前 Claude 会话 token 即将耗尽,或需要切换到其他模型(如 DeepSeek)时,执行此命令生成完整的状态快照,让新会话能无缝接管所有工作。

---

立即执行以下步骤收集信息:

**1. 读配置**:
`cat .aiagents/config.json 2>/dev/null || cat .claude/agents.conf 2>/dev/null || echo "(配置不存在)"`

**2. 查 spec 文件状态**:
`ls -la docs/ai-agents/specs/*.md 2>/dev/null || echo "(无 spec 文件)"`

**3. 查信号 + 状态**:
`bash .aiagents/bin/agentctl.sh status`

**4. 查 git 状态**:
`git log --oneline -5 2>/dev/null; echo "---"; git status --short 2>/dev/null`

**5. 查最新日志尾部**:
`tail -15 .aiagents/logs/be_$(date +%Y%m%d).log 2>/dev/null; echo "--- FE ---"; tail -15 .aiagents/logs/fe_$(date +%Y%m%d).log 2>/dev/null`

**6. 查事件流末尾**:
`tail -50 .aiagents/state/events.jsonl 2>/dev/null`

**7. 查 memory 摘要**:
`head -30 .aiagents/memory/global/patterns.md 2>/dev/null; echo "---"; head -30 .aiagents/memory/projects/context.md 2>/dev/null`

---

综合以上信息,将以下内容写入 `docs/ai-agents/specs/00-交接.md`:

```
# 工作流交接文档
生成时间: <当前时间>
原会话模型: <如实填写>

---
## 项目配置
- 后端目录 / 栈: <BACKEND_DIR> — <BACKEND_STACK>
- 前端目录 / 栈: <FRONTEND_DIR> — <FRONTEND_STACK>
- 后端测试命令: <BACKEND_TEST_CMD>
- 前端测试命令: <FRONTEND_TEST_CMD>
- 后端 Lint: <BACKEND_LINT_CMD>

---
## 当前工作流阶段
**阶段**: <从 spec 文件 + state/current.json 推断>

**立即下一步操作**: <一句话描述新 agent 接手后第一件事>

---
## Spec 文件状态
| 文件 | 状态 | 最后修改 | 摘要 |
|------|------|----------|------|
| 01-需求.md | <存在✅/不存在❌> | <时间> | <一句话> |
| 02-后端编码.md | <存在✅/不存在❌> | <时间> | <一句话> |
| 03-前端编码.md | <存在✅/不存在❌> | <时间> | <一句话> |
| 04-Bug修复-*.md | <存在✅/不存在❌> | <时间> | <一句话> |

---
## 审查报告状态
| 文件 | 最新轮 | 结论 |
|------|--------|------|
| reviews/backend-review.md | 第 N 轮 | ✅/❌ |
| reviews/frontend-review.md | 第 N 轮 | ✅/❌ |

---
## 状态快照(.aiagents/state/current.json 摘录)
<列出 backend.state / frontend.state / workers 状态>

---
## 用户已确认的关键决策
(从本次会话对话中总结,包括:需求范围、技术选型、接口设计、已跳过的功能等)
- <决策 1>
- <决策 2>

---
## 未完成/待处理事项
- <待处理项 1>
- <待处理项 2>

---
## Memory 摘要
- patterns.md 最近 3 条
- bugs.md 最近 3 条
- projects/context.md 关键决策

---
## 给新 Agent 的操作指令
新会话启动后必须按顺序执行:
1. 阅读本文件(你现在正在做)
2. 阅读 CLAUDE.md(角色定义和审查 rubric)
3. 读 .aiagents/memory/ 下 4 份记忆文件
4. 运行 /status 确认实时状态
5. <具体操作指令,如"运行 /dispatch-frontend 派发前端">
6. 向用户确认: "我已读取交接文档,当前阶段是 <X>,接下来将 <Y>,请确认是否继续"
```

---

写完后告知用户:
> 交接文档已写入 `docs/ai-agents/specs/00-交接.md`。
>
> **切换模型步骤**:
> 1. 在新模型/新会话里切换到项目目录,运行 `claude .`(或对应 CLI)
> 2. 新模型会读到 CLAUDE.md 中的"新会话启动规程",自动查找 `00-交接.md`
> 3. 如果新模型不支持 CLAUDE.md 自动加载,把 `00-交接.md` 内容手动粘贴到第一条消息里
> 4. **注意**: 不支持 slash commands 的模型,需要用等价的 Bash 命令手动操作信号文件
