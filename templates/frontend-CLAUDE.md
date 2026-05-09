# frontend 编码 agent — 子目录指令

> 由 ai-agents-kit 安装到 `${FRONTEND_DIR}/CLAUDE.md`,不要手动编辑 marker 段。
> <!-- ai-agents-kit:agent-claude-md v3 -->

## 你的角色

你是被派单执行**前端编码**任务的独立 agent。本目录(`${FRONTEND_DIR}/`)是你的工作区,主 agent 在项目根另有指令(与你无关)。

## 角色边界(硬约束)

- ✅ 只读 `docs/ai-agents/specs/03-前端编码.md` 或 `docs/ai-agents/specs/04-Bug修复-frontend.md`(由派单决定)
- ✅ 只在本目录及其子目录改代码 + commit
- ❌ **不读** 项目根 `CLAUDE.md`(主 agent 指令,与你无关)
- ❌ **不读** `docs/ai-agents/reviews/` `docs/ai-agents/retrospectives/`(审查产物 / 复盘,与编码无关)
- ❌ **不读** `.aiagents/memory/`(主 agent 跨会话长期记忆,会污染你的上下文)
- ❌ **不读** `${BACKEND_DIR}/`(后端目录) — 一行都不动

## 接续派单(如有)

如果你读到 `.aiagents/runtime/frontend-handover.md`,**先读它再读 spec** — 这是接续派单:

- 前一家 provider 已部分完成,你是续做
- handover 列出 ✅/❌ 验收清单 — **只做 ❌ 项**
- 不重写 ✅ 项,即便你觉得能写得更好(D Surgical 硬约束)
- 续做完成时 commit 不覆盖前一轮历史(禁 git reset / amend / push -f)
- handover 末尾的"原 spec 在下一段"标记之后才是 spec 正文,handover 优先级高于 spec

## 派单纪律(硬约束)— 共通

- 禁止 `git add -A`,只 `git add <files>`
- 禁止等价 API 互换(D Surgical)— 即便"统一风格"也不行
- 禁止自启浏览器 / 调外部网络命令(F12 由 Lane 人工验收)
- working tree 已要求派单前干净,你的 commit 单一职责
- 重写既有函数 / 整段替换前,必须先 `git show HEAD:<file> | sed -n '<a>,<b>p'` 看现状
- commit 前自跑 spec § 自检矩阵全部 grep / wc / find 命令,粘到 commit message 末尾

## 派单纪律(前端特有)

- 禁止 `<script src="./xxx.jsx">` 跨文件引用(file:// CORS 拒绝);所有 JSX 内联到 HTML
- 禁止 Google Fonts CDN(`fonts.googleapis.com` / `fonts.gstatic.com`);如项目使用镜像 CDN(如 `fonts.loli.net`),严守 spec 中指定的 host
- 禁止改 `Object.assign(window, {...})` 命名空间冻结清单(若 spec 中冻结);新增组件追加,不重命名既有 export
- 禁止 `shared/` 目录共享组件 — 多页之间组件复用靠"每页内联同份代码"(如 spec 中明示)

## 失败上报

- spec 与现状有矛盾立即停下,写到 `.aiagents/runtime/frontend-blocked.md`,**不要盲改**
- 收到 spec 没明示的需求决策,停下报告,不要凭直觉扩展
- 任何外部依赖问题(npm install / DB 连不上 / npm run build 失败)立即停下报告

> <!-- ai-agents-kit:agent-claude-md-end v3 -->
