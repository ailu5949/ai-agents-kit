---
description: Provider 切换接续 — claude 失败 → 切 codex(或反向),保任务一致性不重做
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*)
---

> **Usage**: `/retry-other-provider <backend|frontend>`
>
> **流程**:
> 1. agentctl 读 events.jsonl 找上次该 agent 用的 provider + 失败原因
> 2. 从 config.json 找另一家 provider(若仅一家则报错)
> 3. 生成 `.aiagents/runtime/<agent>-handover.md` 骨架(列前一家 commits / 未提交改动 / 失败原因 + 空 ✅/❌ 段)
> 4. **主 Claude 待填**: 跑 spec § 自检 grep 矩阵 填 ✅/❌ 每条验收点
> 5. 主 Claude 调 `/dispatch-<agent> --provider <other>` 派对家
> 6. agent-runner.sh 检测 handover.md 存在 → prepend 到 prompt → 新 provider 读到接续依据
> 7. 派单成功后 handover.md 自动归档到 `runtime/archive/`

**执行**:

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" retry-other-provider $ARGUMENTS
```

**何时合理用**:
- claude 派单失败,原因是 token quota / rate limit / 529 — 切 codex 试试
- codex 派单失败,原因是 sandbox CreateProcessAsUserW / 网络抖动 — 切 claude 试试
- **同一 spec** 想换 provider 接续(不是新需求)

**何时不能用**:
- spec 本身有 bug → 应该走 04 修复,不是换 provider
- 业务码逻辑错(测试 fail / lint error)→ 04 修复
- 不知道为什么失败 → 先看 events.jsonl + log 末尾再决定

**填 handover ✅/❌ 的硬要求**(主 Claude 责任):
- 不填直接 dispatch → 新 provider 看到空段会重做 → 浪费 token
- 跑 spec § 自检 grep 矩阵 / 看 git log 历史 / 看 working tree diff 综合判断
- ✅ 项要给具体证据(`file.py:42 已实现`),不是空 ✅
- ❌ 项要写"还差什么"(`tests/test_x.py 第 N 行的 assert 还在 NotImplementedError`)

**关联 spec**: [docs/designs/2026-05-09-multi-provider-design.md § 7.5 Handover 机制](../../../docs/designs/2026-05-09-multi-provider-design.md)
