#!/usr/bin/env bash
# wait-signal.sh — 等待 Codex agent 完成信号,最长 9 分钟一轮。
# v2: 信号目录从 docs/superpowers/signals → .aiagents/signals。
#
# 用法: bash wait-signal.sh <backend|frontend> [等待秒数(默认 540)]
# 退出码:
#   0 = 检测到 *_done   (Codex 完成,可以审查)
#   1 = 检测到 *_failed (Codex 失败,生成修复单)
#   2 = 检测到 *_timeout(Codex 超时/卡死,通知用户检查网络)
#   3 = 等待上限到了仍无信号(Codex 仍在跑,Stop hook 兜底)
#
# 副作用: 消费掉信号文件(mv 到 .consumed_*),防止 Stop hook 二次触发。
#
# 提示: 也可以直接用 `bash .aiagents/bin/agentctl.sh wait backend`,等价。

set -uo pipefail

KIND="${1:-backend}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIGS="$ROOT/.aiagents/signals"
WAIT_MAX="${2:-540}"
POLL_INTERVAL=5

START=$(date +%s)

consume() {
  local f="$1"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  mv "$f" "${f%/*}/.consumed_$(basename "$f")_${ts}" 2>/dev/null || rm -f "$f" || true
}

echo "⏳ $(date '+%H:%M:%S') 开始等待 Codex-${KIND} 完成信号(最长 ${WAIT_MAX}s)..."

while true; do
  ELAPSED=$(( $(date +%s) - START ))

  if [ -f "$SIGS/${KIND}_done" ]; then
    consume "$SIGS/${KIND}_done"
    echo ""
    echo "✅ $(date '+%H:%M:%S') 检测到 ${KIND}_done (耗时 ${ELAPSED}s)"
    exit 0
  fi

  if [ -f "$SIGS/${KIND}_failed" ]; then
    REASON="$(head -c 400 "$SIGS/${KIND}_failed" 2>/dev/null | tr '\n' ' ')"
    consume "$SIGS/${KIND}_failed"
    echo ""
    echo "❌ $(date '+%H:%M:%S') 检测到 ${KIND}_failed (耗时 ${ELAPSED}s)"
    echo "   原因: $REASON"
    exit 1
  fi

  if [ -f "$SIGS/${KIND}_timeout" ]; then
    REASON="$(head -c 200 "$SIGS/${KIND}_timeout" 2>/dev/null | tr '\n' ' ')"
    consume "$SIGS/${KIND}_timeout"
    echo ""
    echo "⏰ $(date '+%H:%M:%S') 检测到 ${KIND}_timeout — ${REASON}"
    exit 2
  fi

  if [ $ELAPSED -ge "$WAIT_MAX" ]; then
    echo ""
    echo "⚠️ $(date '+%H:%M:%S') 等待 ${WAIT_MAX}s 无信号 — Codex 可能仍在运行"
    exit 3
  fi

  printf "\r  ⏳ 等待 Codex-%-8s %3ds / %ds  " "$KIND" "$ELAPSED" "$WAIT_MAX"
  sleep "$POLL_INTERVAL"
done
