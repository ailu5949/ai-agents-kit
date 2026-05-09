# 失败模式 (Bugs / Anti-patterns)

> 跨项目可复用的"踩过的坑"。Claude 每轮任务开始前扫一眼，避免重复犯错。

格式约定：每条用 `## YYYY-MM-DD HH:MM` 开头，描述现象、原因、教训。

例：

## 2026-04-28 15:30

**现象**：Vite + React 项目 `npm run dev` 报 JSX 语法错。
**原因**：`package.json` 缺 `@vitejs/plugin-react` 但 `vite.config.js` 已经 `import react()`。
**教训**：审查 sanity 检查里**必须**对 plugin import 与 dependency 做交叉验证。

---
