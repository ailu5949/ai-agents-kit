#!/usr/bin/env bash
# 被 /status slash command 调用。输出三个 agent 的当前状态。

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIG_DIR="$PROJECT_ROOT/docs/superpowers/signals"
LOG_DIR="$PROJECT_ROOT/docs/superpowers/logs"

state_of() {
  local kind="$1"
  if   [ -f "$SIG_DIR/task_ready_${kind}" ]; then echo "⏳ 队列中(已派发,Codex 尚未开工)"
  elif [ -f "$SIG_DIR/bugfix_${kind}" ];     then echo "⏳ 修复队列中"
  elif [ -f "$SIG_DIR/${kind}_done" ];       then echo "✅ 已完成,待 Claude 审查"
  elif [ -f "$SIG_DIR/${kind}_failed" ];     then echo "❌ 失败($(head -c 100 "$SIG_DIR/${kind}_failed" | tr '\n' ' '))"
  else echo "💤 空闲"
  fi
}

log_tail() {
  local kind="$1"
  local abbr="be"
  [ "$kind" = "frontend" ] && abbr="fe"
  local latest=""
  if [ -d "$LOG_DIR" ]; then
    latest="$(ls -1t "$LOG_DIR"/${abbr}_*.log 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$latest" ] && [ -f "$latest" ]; then
    echo "--- 最近日志($(basename "$latest") 尾 20 行)---"
    tail -20 "$latest"
  else
    echo "(暂无日志)"
  fi
}

echo "=========================================="
echo "  三 Agent 状态快照 · $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo
echo "【Backend】 $(state_of backend)"
log_tail backend
echo
echo "【Frontend】 $(state_of frontend)"
log_tail frontend
echo
echo "【Signal 目录】 $SIG_DIR"
ls -la "$SIG_DIR" 2>/dev/null | grep -v '^total' | grep -v '^d' || echo "(空)"
