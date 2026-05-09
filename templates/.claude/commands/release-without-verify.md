---
description: 应急 — 跳过主 Claude 真打验证,直接推进 ready-for-human (Lane 显式破例)
allowed-tools: Bash(bash .aiagents/bin/agentctl.sh:*), Bash(bash *.aiagents/bin/agentctl.sh:*), Bash(pwsh .aiagents/bin/agentctl.ps1:*)
---

> **Usage**: `/release-without-verify <backend|frontend> "<reason>"`
>
> 例: `/release-without-verify backend "生产 hot-fix,LLM 限流影响 verify"`
>
> **后果**:
> - state 直接 done-awaiting-review → ready-for-human(跳过 claude-verifying)
> - events.jsonl 写入 `phase=verify-bypassed` 记录
> - `.aiagents/memory/global/bugs.md` 自动追加破例条目(供未来 review 核查)
>
> **默认 OFF**,Lane 主动敲。每次破例进 memory。

**执行**:

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" release-without-verify $ARGUMENTS
```

**何时合理用**:
- 生产环境 hot-fix,verify gate 跑测试需要的 PG / 第三方 API 暂时不可达
- E2E 卡 LLM 限流 / 网络抖动,但代码本身已经被 git diff + grep 矩阵验证过
- 某种集成测试本机无法跑(如 GPU / 真账号),Lane 自己手动验证后破例

**何时不能用**:
- 单元测试还在 fail / lint 还有 error → 应走 04 修复,不走破例
- "懒得跑测试" → 严禁
- 不写 reason / reason 太空泛("急")→ memory 会留痕,后续 review 会回头追究

**破例后**:
- Lane 应在合适时机补跑 verify 清单,把结果记到对应阶段回顾
- 主 Claude 看到 `bugs.md` 中破例条目时,在下一阶段 review 中**主动**核查该轮是否有遗漏 bug
