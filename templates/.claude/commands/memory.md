---
description: 写入一条经验到 .aiagents/memory/global/patterns.md
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

把用户明确要求沉淀的经验,或本轮完成后值得跨项目复用的经验,写入 memory。

执行:

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" memory "这里写一条可复用经验"
```

写入后告诉用户保存到了 `.aiagents/memory/global/patterns.md`。

注意:
- 单条经验要足够具体,例如"Spring Boot 接口分页统一用 `Page<T>` 返回"比"Spring Boot 接口要规范"好
- 失败模式应写到 `.aiagents/memory/global/bugs.md`,项目独有上下文写到 `projects/context.md`,产品想法写到 `ideas/product-ideas.md`
- 这些 memory 文件 Claude **每次任务开始时**都会读取(见 CLAUDE.md "Memory 使用规范")
