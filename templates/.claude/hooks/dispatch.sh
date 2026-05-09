#!/usr/bin/env bash
# 被 slash command 调用,写信号文件触发 Codex watcher。
#
# 用法:
#   dispatch.sh backend          # 派后端新任务(读 02-后端编码.md)
#   dispatch.sh frontend         # 派前端新任务(读 03-前端编码.md)
#   dispatch.sh bugfix-backend   # 派后端修复(读 04-Bug修复-backend.md)
#   dispatch.sh bugfix-frontend  # 派前端修复(读 04-Bug修复-frontend.md)

set -euo pipefail

KIND="${1:-}"
if [ -z "$KIND" ]; then
  echo "用法: dispatch.sh {backend|frontend|bugfix-backend|bugfix-frontend}" >&2
  exit 2
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIG_DIR="$PROJECT_ROOT/docs/superpowers/signals"
SPEC_DIR="$PROJECT_ROOT/docs/superpowers/specs"
mkdir -p "$SIG_DIR"

case "$KIND" in
  backend)
    SPEC="$SPEC_DIR/02-后端编码.md"
    SIGNAL="$SIG_DIR/task_ready_backend"
    ;;
  frontend)
    SPEC="$SPEC_DIR/03-前端编码.md"
    SIGNAL="$SIG_DIR/task_ready_frontend"
    ;;
  bugfix-backend)
    SPEC="$SPEC_DIR/04-Bug修复-backend.md"
    SIGNAL="$SIG_DIR/bugfix_backend"
    ;;
  bugfix-frontend)
    SPEC="$SPEC_DIR/04-Bug修复-frontend.md"
    SIGNAL="$SIG_DIR/bugfix_frontend"
    ;;
  *)
    echo "未知类型: $KIND" >&2
    exit 2
    ;;
esac

if [ ! -f "$SPEC" ]; then
  echo "派发失败: 规格文件不存在 $SPEC" >&2
  echo "请先让 Claude 生成该文件,再调用此命令。" >&2
  exit 3
fi

TS="$(date -Iseconds)"
printf '{"kind":"%s","spec":"%s","dispatched_at":"%s"}\n' "$KIND" "$SPEC" "$TS" > "$SIGNAL"

echo "✅ 派发成功: $KIND"
echo "   信号文件: $SIGNAL"
echo "   规格文件: $SPEC"
echo "   时间戳: $TS"
