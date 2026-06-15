---
description: 用异构 provider(默认 codex)对编码 agent 交付做对抗性找茬审查
---

对 `$ARGUMENTS`(backend / frontend)的最新交付做**对抗性审查** —— 用一个跟编码 agent 异构的 provider(默认 codex)独立找茬,防"主 Claude 既写 spec 又审、同体盲区"。

## 前置条件(不满足就别跑)

1. `workflow.adversarial_review.enabled == true`(`jq '.workflow.adversarial_review' .aiagents/config.json` 确认;false 则本步骤跳过,不是必经)
2. 该 agent **已过** Pre-Human Decision Gate 的真打验证(pytest / lint / curl smoke 全绿)—— 对抗审查是真打验证**之后**、推 `ready-for-human`**之前**的最后一道
3. reviewer CLI 已就绪(默认 codex;`bash .aiagents/bin/agentctl.sh doctor` 看环境行)

## 步骤

1. **跑脚本**(用绝对路径,审查中 `cd` 会改工作目录):
   ```bash
   bash "$(git rev-parse --show-toplevel)/.aiagents/bin/adversarial-review.sh" <backend|frontend>
   ```
   脚本会:用 codex 独立读 spec + git diff(本轮 baseline..HEAD)+ 自己跑 git/grep → 落报告 `docs/ai-agents/reviews/adversarial-<agent>-<ts>.md` → 末行输出 `VERDICT: PASS|FAIL`,exit 0/1/3。

2. **读脚本生成的报告全文**(不要只看 exit code):`docs/ai-agents/reviews/adversarial-<agent>-<ts>.md`

3. **你是最终仲裁者**,按 exit code + 报告内容决策:

   | 脚本结果 | 你做什么 |
   |---|---|
   | exit 0 / `VERDICT: PASS` | 把对抗审查结论追加进 `reviews/<agent>-review.md` 的 § 对抗审查段,然后推 `state=ready-for-human` |
   | exit 1 / `VERDICT: FAIL` | 读报告里每条"高/中"严重度问题,**逐条核实**(codex 也可能误判)→ 确认成立的问题并入 `docs/ai-agents/specs/04-Bug修复-<agent>.md` → `/bugfix-<agent>` 派回编码 agent → 回到验证起点 |
   | exit 3 / 未解析到 VERDICT | reviewer 异常(超时/崩)→ **不得默认通过**,人工读报告判定,或修好 reviewer 重跑 |

4. **仲裁纪律**:
   - codex 报的问题**默认成立**,要推翻必须在 review 报告里给出反驳证据(读代码/跑测试证明 codex 看错了),不能凭"它应该没事"略过
   - 你**不直接改业务代码**修 codex 找到的问题 —— 仍走 04 修复 → 派回编码 agent(settings.json deny 强制)
   - 对抗审查 FAIL 修复后,**重新**跑真打验证 + 再跑一次对抗审查(不是只补那一处)

## 与现有审查的关系

```
编码 agent done
  → Karpathy 6 项(你自己审,对照你写的 02/03)
  → 真打验证(你跑 pytest/lint/curl)
  → 【本命令】对抗审查(codex 独立找茬,换一个脑子)   ← 防同体盲区
  → ready-for-human(Lane 拍板)
```

Karpathy 6 项 + 真打验证是"自查",对抗审查是"他查"。两者都过才推人工。
