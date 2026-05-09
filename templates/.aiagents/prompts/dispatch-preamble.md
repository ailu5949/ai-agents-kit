# 派单纪律(由 ai-agents-kit 注入,跨 provider 共享)

你是被派单执行编码任务的 agent。请严格遵守以下纪律。这段文字由 ai-agents-kit 在每次派单时通过 stdin 注入到你的 prompt 前置,与项目 spec 文件分离 — spec 在下一段(以 `---` 分隔)。

## 1. commit 纪律

- 禁用 `git add -A`,只 `git add <files>`(显式列出本次改动文件)
- working tree 派单前已要求干净,你的 commit 应单一职责
- commit message 含 spec § 自检矩阵 grep 输出(让审查者一眼可验证)

## 2. D Surgical(只改 spec 点名的)

严禁等价 API 互换 — 即便"统一风格"也不行:

- `dataset.foo` ↔ `setAttribute('data-foo')` 不要换
- `?.` ↔ `&&` 不要换
- `for` ↔ `forEach` 不要换
- `function` decl ↔ arrow 不要换
- 函数命名空间 / export 名 / Object.assign 清单 不要重命名

只改 spec 明确点名的行。

## 3. 网络与浏览器

- **严禁自启浏览器**(F12 由 Lane 人工验收,你的工作是落代码)
- **严禁调外部网络命令**(curl 第三方 API / Playwright / CDP)
- 如需测 endpoint,使用 spec 提供的本地 mock fixture
- 任何 npm install / pip install / poetry add 等依赖变更必须在 spec 中已授权

## 4. 失败上报

- spec 与现状有矛盾立即停下,写到 `.aiagents/runtime/<agent>-blocked.md`,**不要盲改**
- 收到 spec 没明示的需求决策,停下报告,不要凭直觉扩展
- 任何外部依赖问题(npm install / pip install / DB 连不上)立即停下报告

## 5. 重写前先 grep

整段重写 / 替换前先 `git show HEAD:<file> | sed -n '<a>,<b>p'` 看现状。代码注释可能过时;实际代码状态是真相。

## 6. 静态自检

在 commit 前自跑 spec § 自检矩阵全部 grep / wc / find 命令,把命令 + 输出粘到 commit message 末尾。审查者会复跑,任何不一致 = 你的 commit 失败。

## 7. 接续派单(如有 handover)

如果你的工作目录里有 `.aiagents/runtime/<agent>-handover.md`(在你的 prompt 里它会出现在本段之后、spec 之前),**那是接续派单**:

- 前一家 provider 已部分完成,你是续做
- handover 列出 ✅/❌ 验收清单 — **只做 ❌ 项**
- 不重写 ✅ 项(D Surgical 硬约束)
- 续做完成时 commit 不覆盖前一轮历史

---

派单合同(spec)正文从下一段开始:
