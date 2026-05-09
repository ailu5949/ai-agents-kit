#!/usr/bin/env bash
# ai-agents-kit v2 tmux 启动方案: 一屏三窗格,共享 .aiagents/ 配置。
# 与三终端方案等价,只是把三个面板压进一个 tmux session。

set -euo pipefail

SESSION="${AGENTS_TMUX_SESSION:-agents}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

# 配置: 优先 .aiagents/config.json,回退 .claude/agents.conf(向后兼容)
BACKEND_DIR="${BACKEND_DIR:-}"
FRONTEND_DIR="${FRONTEND_DIR:-}"

if [ -z "$BACKEND_DIR" ] || [ -z "$FRONTEND_DIR" ]; then
  if [ -f "$PROJECT_ROOT/.aiagents/config.json" ] && command -v jq >/dev/null 2>&1; then
    BACKEND_DIR="${BACKEND_DIR:-$(jq -r '.backend.dir' "$PROJECT_ROOT/.aiagents/config.json" 2>/dev/null || echo)}"
    FRONTEND_DIR="${FRONTEND_DIR:-$(jq -r '.frontend.dir' "$PROJECT_ROOT/.aiagents/config.json" 2>/dev/null || echo)}"
  fi
  if [ -z "$BACKEND_DIR" ] && [ -f "$PROJECT_ROOT/.claude/agents.conf" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.claude/agents.conf"
  fi
fi
: "${BACKEND_DIR:=erp-be}"
: "${FRONTEND_DIR:=erp-fe}"

BE_ABS="$PROJECT_ROOT/$BACKEND_DIR"
FE_ABS="$PROJECT_ROOT/$FRONTEND_DIR"
BIN_DIR="$PROJECT_ROOT/.aiagents/bin"
SIG_DIR="$PROJECT_ROOT/.aiagents/signals"

command -v tmux >/dev/null 2>&1 || { echo "❌ 未找到 tmux (WSL/Linux 下 sudo apt install tmux)"; exit 1; }
[ -d "$BE_ABS" ] || { echo "❌ 后端目录不存在: $BE_ABS"; exit 1; }
[ -d "$FE_ABS" ] || { echo "❌ 前端目录不存在: $FE_ABS"; exit 1; }
[ -x "$BIN_DIR/agentctl.sh" ] || [ -f "$BIN_DIR/agentctl.sh" ] || { echo "❌ 缺少 $BIN_DIR/agentctl.sh (跑 install.sh 了吗?)"; exit 1; }

# 自动探测 claude 可执行路径
if [ -z "${CLAUDE_CMD:-}" ]; then
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CMD="claude"
  elif [ -x "/mnt/c/Users/$USER/.local/bin/claude.exe" ]; then
    CLAUDE_CMD="/mnt/c/Users/$USER/.local/bin/claude.exe"
  elif [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_CMD="$HOME/.local/bin/claude"
  else
    echo "❌ 找不到 claude 可执行文件,请设置 CLAUDE_CMD 环境变量"
    exit 1
  fi
fi

mkdir -p "$SIG_DIR"
# 仅清 done/failed/timeout/consumed,保留排队中的 task_ready_*/bugfix_*
rm -f "$SIG_DIR"/*_done "$SIG_DIR"/*_failed "$SIG_DIR"/*_timeout "$SIG_DIR"/.consumed_* 2>/dev/null || true

echo "🚀 Starting Agents · project=$PROJECT_NAME · session=$SESSION"
echo "   backend  = $BE_ABS"
echo "   frontend = $FE_ABS"
echo "   claude   = $CLAUDE_CMD"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "📎 Attach 到已有 session"
  tmux attach -t "$SESSION"
  exit 0
fi

# 三窗格布局: 上 Claude,左下 Backend,右下 Frontend
tmux new-session -d -s "$SESSION" -x 220 -y 55 -c "$PROJECT_ROOT"
tmux rename-window -t "${SESSION}:0" "agents"

tmux split-window -v -t "${SESSION}:0" -p 50 -c "$PROJECT_ROOT"
tmux split-window -h -t "${SESSION}:0.1" -c "$PROJECT_ROOT"

tmux select-pane -t "${SESSION}:0.0" -T "CLAUDE"
tmux select-pane -t "${SESSION}:0.1" -T "CODEX-BE"
tmux select-pane -t "${SESSION}:0.2" -T "CODEX-FE"

tmux send-keys -t "${SESSION}:0.0" "$CLAUDE_CMD" Enter
tmux send-keys -t "${SESSION}:0.1" "bash $BIN_DIR/agentctl.sh watch backend" Enter
tmux send-keys -t "${SESSION}:0.2" "bash $BIN_DIR/agentctl.sh watch frontend" Enter

tmux select-pane -t "${SESSION}:0.0"

echo "✅ 三窗格就绪。attaching..."
echo "   Ctrl+b d  退出 tmux 但保留 session"
echo "   tmux kill-session -t $SESSION  彻底关闭"

tmux attach -t "$SESSION"
