#!/usr/bin/env bash
# ai-agents-kit v2: 参数化 watcher。watcher 只监听 signal 和调度 runner,不直接调用 Codex。
# 用法: bash watch-agent.sh <backend|frontend>

set -euo pipefail

AGENT="${1:-backend}"
[ "$AGENT" = backend ] || [ "$AGENT" = frontend ] || { echo "watch 只支持 backend/frontend" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIG_DIR="$ROOT/.aiagents/signals"
BIN_DIR="$ROOT/.aiagents/bin"
RUNTIME_DIR="$ROOT/.aiagents/runtime"
HEARTBEAT_DIR="$RUNTIME_DIR/heartbeats"
WORKER_LOG_DIR="$ROOT/.aiagents/logs"
mkdir -p "$SIG_DIR" "$HEARTBEAT_DIR" "$WORKER_LOG_DIR"

PYTHON_BIN=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "pass" >/dev/null 2>&1; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo "缺少可用的 python(注意 Windows 上的 python3 可能是 Store stub),watcher 无法运行" >&2; exit 1; }

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

WORKER_LOG="$WORKER_LOG_DIR/worker-${AGENT}.log"

write_worker() {
  local status="$1"
  "$PYTHON_BIN" - "$RUNTIME_DIR/workers.json" "$AGENT" "$status" "$$" "$WORKER_LOG" <<'PY'
import json, os, sys, datetime
path, agent, status, pid, log_path = sys.argv[1:6]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    data = {}
entry = data.get(agent, {})
now = datetime.datetime.now().astimezone().isoformat()
if status == "running":
    entry.update({
        "pid": int(pid),
        "status": "running",
        "started_at": entry.get("started_at") or now,
        "updated_at": now,
        "command": f"bash .aiagents/bin/agentctl.sh watch {agent}",
        "log": log_path,
    })
else:
    entry.update({
        "pid": int(pid),
        "status": status,
        "updated_at": now,
        "stopped_at": now,
    })
data[agent] = entry
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w", encoding="utf-8").write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
}

write_heartbeat() {
  "$PYTHON_BIN" - "$HEARTBEAT_DIR/$AGENT.json" "$AGENT" "$$" <<'PY'
import json, os, sys, datetime
path, agent, pid = sys.argv[1:4]
payload = {
    "agent": agent,
    "pid": int(pid),
    "status": "running",
    "updated_at": datetime.datetime.now().astimezone().isoformat(),
}
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w", encoding="utf-8").write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
PY
}

append_event() {
  local status="$1" message="$2"
  "$PYTHON_BIN" - "$ROOT/.aiagents/state/events.jsonl" "$AGENT" "$status" "$message" <<'PY'
import json, os, sys, datetime
path, agent, status, message = sys.argv[1:5]
os.makedirs(os.path.dirname(path), exist_ok=True)
payload = {
    "time": datetime.datetime.now().astimezone().isoformat(),
    "agent": agent,
    "status": status,
    "message": message,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
}

refresh_state() {
  bash "$BIN_DIR/agentctl.sh" status >/dev/null 2>&1 || true
}

cleanup() {
  write_worker "stopped" || true
  append_event "watcher-stopped" "watcher 已停止" || true
  refresh_state
}
trap cleanup EXIT INT TERM

echo "Codex-$AGENT watcher ready · $(date -Iseconds)"
echo "    监听 $SIG_DIR/task_ready_$AGENT 和 $SIG_DIR/bugfix_$AGENT"
write_worker "running"
write_heartbeat
append_event "watcher-started" "watcher 已启动"
refresh_state

while true; do
  write_worker "running"
  write_heartbeat
  refresh_state
  task_signal="$SIG_DIR/task_ready_$AGENT"
  bug_signal="$SIG_DIR/bugfix_$AGENT"

  if [ -f "$task_signal" ]; then
    rm -f "$task_signal"
    echo ""
    echo "🔔 $(date '+%H:%M:%S') 检测到 $AGENT 新任务,交给 agent-runner.sh"
    bash "$BIN_DIR/agent-runner.sh" "$AGENT" task || true
  fi

  if [ -f "$bug_signal" ]; then
    rm -f "$bug_signal"
    echo ""
    echo "🔧 $(date '+%H:%M:%S') 检测到 $AGENT 修复任务,交给 agent-runner.sh"
    bash "$BIN_DIR/agent-runner.sh" "$AGENT" bugfix || true
  fi

  sleep 2
done
