#!/usr/bin/env bash
# ai-agents-kit v2 Stop hook: Claude 每次 turn 结束时执行。
#
# 设计:
# - 检测到 *_done / *_failed / *_timeout 信号时,返回 {"decision":"block","reason":"..."}
#   让 Claude 在下一个 turn 自动进入审查流程。
# - 同时刷新 .aiagents/state/current.json 让外部 console / 后续 status 命令读到最新状态。
# - 关键: 无信号时必须静默 exit 0,否则每次对话都会被无意义打断。
# - 依赖: jq 优先,python 兜底(二者有其一即可)。
#
# 触发优先级(对 Claude 的提示口径):
# 1. signal 是触发器,不是状态权威
# 2. state/current.json 才是审查决策依据
# 3. Claude 看到本提示后必须按 CLAUDE.md 的 Karpathy rubric 处理

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIG_DIR="$ROOT/.aiagents/signals"
STATE_FILE="$ROOT/.aiagents/state/current.json"
[ -d "$SIG_DIR" ] || exit 0

events=""

for kind in backend frontend; do
  done_file="$SIG_DIR/${kind}_done"
  failed_file="$SIG_DIR/${kind}_failed"
  timeout_file="$SIG_DIR/${kind}_timeout"
  ts="$(date +%Y%m%d_%H%M%S)"

  if [ -f "$done_file" ]; then
    events+="- ✅ ${kind} 开发完成,请立即审查"$'\n'
    mv "$done_file" "$SIG_DIR/.consumed_${kind}_done_${ts}" 2>/dev/null || rm -f "$done_file"
  fi
  if [ -f "$failed_file" ]; then
    reason="$(head -c 400 "$failed_file" 2>/dev/null | tr '\n' ' ')"
    events+="- ❌ ${kind} 开发失败: ${reason}"$'\n'
    mv "$failed_file" "$SIG_DIR/.consumed_${kind}_failed_${ts}" 2>/dev/null || rm -f "$failed_file"
  fi
  if [ -f "$timeout_file" ]; then
    reason="$(head -c 200 "$timeout_file" 2>/dev/null | tr '\n' ' ')"
    events+="- ⏰ ${kind} Codex 超时(可能网络卡死): ${reason}"$'\n'
    events+="  → 建议告知用户检查 watcher 终端输出,确认网络恢复后重新 /dispatch-${kind}"$'\n'
    mv "$timeout_file" "$SIG_DIR/.consumed_${kind}_timeout_${ts}" 2>/dev/null || rm -f "$timeout_file"
  fi
done

# 检测 state.json 中的 ready-for-human 状态(由 verify gate 通过 / release-without-verify 触发)
# claude-verifying 不触发 hook(那是主 Claude 自己正在跑 verify,不要打断)
if [ -f "$STATE_FILE" ]; then
  for kind in backend frontend; do
    cur_state="$(
      python -c "
import json, sys
try:
    d = json.load(open(r'$STATE_FILE', encoding='utf-8'))
    print((d.get('$kind') or {}).get('state') or '')
except Exception:
    pass
" 2>/dev/null || true
    )"
    if [ "$cur_state" = "ready-for-human" ]; then
      events+="- 🟢 ${kind} verify 全过,等待 Lane 决策(收下 / 打回 / 推迟)"$'\n'
    fi
  done
fi

[ -z "$events" ] && exit 0

# 摘录当前 state(若存在)给 Claude 一个权威状态参考
state_excerpt=""
if [ -f "$STATE_FILE" ]; then
  state_excerpt="$(head -c 2000 "$STATE_FILE" 2>/dev/null || true)"
fi

body="[Stop hook] 检测到 Codex 状态变化(wait 命令未消费时由此兜底):
${events}
权威状态参考(.aiagents/state/current.json 摘录):
${state_excerpt}

注意:
- signal 只是触发器;state.<agent>.state == \"done-awaiting-review\" 才是审查依据
- 如果 wait-signal.sh / agentctl.sh wait 已经处理过对应信号,忽略本条即可

按 CLAUDE.md 的 Karpathy 审查 rubric 处理:
1. 读 .aiagents/logs/{be|fe}_<date>.log 最新尾部 + .aiagents/state/events.jsonl
2. 对项目目录跑 git diff,确认改动落地
3. 对照 docs/ai-agents/specs/02-后端编码.md / 03-前端编码.md 每条验收标准逐项核对
4. 跑测试和 lint(从 .aiagents/config.json 或 .claude/agents.conf 读)
5. 把审查段落追加到 docs/ai-agents/reviews/backend-review.md 或 frontend-review.md
6. 通过则推进下一阶段,失败则生成 docs/ai-agents/specs/04-Bug修复-*.md 并询问是否 /bugfix-*"

# 探测可用的 Python (Windows 上 python3 经常是 Store stub,跑起来 exit 49)
_python=""
for py in python python3; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c "pass" >/dev/null 2>&1; then
    _python="$py"
    break
  fi
done

if command -v jq >/dev/null 2>&1; then
  jq -n --arg r "$body" '{decision:"block",reason:$r}'
elif [ -n "$_python" ]; then
  "$_python" -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}, ensure_ascii=False))' <<< "$body"
else
  echo "stop-notify: 需要 jq 或 python 来生成 JSON,请安装其中之一" >&2
  exit 0
fi
