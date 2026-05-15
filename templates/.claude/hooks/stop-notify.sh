#!/usr/bin/env bash
# Stop hook: Claude 每次 turn 结束时执行。
# 检测到 编码 agent 完成/失败信号时,返回 JSON {"decision":"block","reason":"..."}
# 让 Claude 在下一个 turn 自动进入审查流程。
#
# 关键: 无信号时必须静默退出 0,否则每次对话都会被无意义打断。
# 依赖: jq 或 python (自动探测，二者有其一即可)

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIG_DIR="$PROJECT_ROOT/docs/superpowers/signals"

[ -d "$SIG_DIR" ] || exit 0

events=""

for kind in backend frontend; do
  done_file="$SIG_DIR/${kind}_done"
  failed_file="$SIG_DIR/${kind}_failed"
  timeout_file="$SIG_DIR/${kind}_timeout"

  if [ -f "$done_file" ]; then
    ts="$(date +%Y%m%d_%H%M%S)"
    events+="- ✅ ${kind} 开发完成,请立即审查"$'\n'
    mv "$done_file" "$SIG_DIR/.consumed_${kind}_done_${ts}" 2>/dev/null || rm -f "$done_file"
  fi
  if [ -f "$failed_file" ]; then
    ts="$(date +%Y%m%d_%H%M%S)"
    reason="$(head -c 400 "$failed_file" 2>/dev/null | tr '\n' ' ')"
    events+="- ❌ ${kind} 开发失败: ${reason}"$'\n'
    mv "$failed_file" "$SIG_DIR/.consumed_${kind}_failed_${ts}" 2>/dev/null || rm -f "$failed_file"
  fi
  if [ -f "$timeout_file" ]; then
    ts="$(date +%Y%m%d_%H%M%S)"
    reason="$(head -c 200 "$timeout_file" 2>/dev/null | tr '\n' ' ')"
    events+="- ⏰ ${kind} 编码 agent 超时(可能网络卡死): ${reason}"$'\n'
    events+="  → 建议告知用户检查面板 $( [ "$kind" = backend ] && echo 2 || echo 3 ) 输出,确认网络恢复后重新 /dispatch-${kind}"$'\n'
    mv "$timeout_file" "$SIG_DIR/.consumed_${kind}_timeout_${ts}" 2>/dev/null || rm -f "$timeout_file"
  fi
done

[ -z "$events" ] && exit 0

body="[Stop hook 兜底] 检测到 编码 agent 状态变化(wait-signal.sh 未消费时由此补充):
${events}
注意: 如果 wait-signal.sh 已经自动处理了对应信号,忽略本条即可。
否则请按 CLAUDE.md 的 Karpathy 审查 rubric 处理:
1. 读 docs/superpowers/logs/ 下最新日志
2. 读对应项目目录的 git diff
3. 对照 02-后端编码.md / 03-前端编码.md 每条验收标准逐项核对
4. 追加审查结论到 docs/superpowers/specs/05-代码审查.md
5. 通过则推进下一阶段,失败则生成 04-Bug修复-*.md 并执行 /bugfix-*"

# 探测可用的 Python (Windows 上 python3 可能不存在或是 Store 包装器)
_python=""
for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1; then
    _python="$py"
    break
  fi
done

if command -v jq >/dev/null 2>&1; then
  jq -n --arg r "$body" '{decision:"block",reason:$r}'
elif [ -n "$_python" ]; then
  "$_python" -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))' <<< "$body"
else
  echo "stop-notify: 需要 jq 或 python 来生成 JSON，请安装其中之一" >&2
  exit 0
fi
