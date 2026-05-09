#!/usr/bin/env bash
# ai-agents-kit v2: Bash 控制入口。
#
# 用法:
#   bash agentctl.sh status                       # 查状态(刷 state/current.json + 日志尾部)
#   bash agentctl.sh dispatch backend             # 派发后端任务(读 02-后端编码.md,写信号)
#   bash agentctl.sh dispatch frontend            # 派发前端任务
#   bash agentctl.sh dispatch bugfix-backend      # 派发后端修复
#   bash agentctl.sh dispatch bugfix-frontend     # 派发前端修复
#   bash agentctl.sh wait backend [seconds]       # 阻塞等待 done/failed/timeout
#   bash agentctl.sh watch backend                # 启动 watcher(交给 watch-agent.sh)
#   bash agentctl.sh memory "经验文本"           # 写一条记忆到 memory/global/patterns.md

set -uo pipefail

COMMAND="${1:-status}"
TARGET="${2:-backend}"
WAIT_SECONDS="${3:-540}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIG_DIR="$ROOT/.aiagents/signals"
STATE_DIR="$ROOT/.aiagents/state"
LOG_DIR="$ROOT/.aiagents/logs"
MEMORY_DIR="$ROOT/.aiagents/memory"
SPEC_DIR="$ROOT/docs/ai-agents/specs"
BIN_DIR="$ROOT/.aiagents/bin"
RUNTIME_DIR="$ROOT/.aiagents/runtime"
CONFIG_JSON="$ROOT/.aiagents/config.json"
CONFIG_CONF="$ROOT/.claude/agents.conf"
mkdir -p "$SIG_DIR" "$STATE_DIR" "$LOG_DIR" "$MEMORY_DIR/global" "$MEMORY_DIR/projects" "$MEMORY_DIR/ideas" "$SPEC_DIR" "$RUNTIME_DIR/heartbeats"

PYTHON_BIN=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "pass" >/dev/null 2>&1; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo "缺少可用的 python(注意 Windows 上的 python3 可能是 Store stub),无法处理 JSON 状态" >&2; exit 1; }

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# ---------- state 写入 ----------
write_state() {
  "$PYTHON_BIN" - "$ROOT" "$STATE_DIR" "$RUNTIME_DIR" "$CONFIG_JSON" "$CONFIG_CONF" <<'PY'
import json, os, sys, datetime, re
root, state_dir, runtime_dir, config_json, config_conf = sys.argv[1:6]
now = datetime.datetime.now().astimezone()

config = None
if os.path.exists(config_json):
    try:
        config = json.load(open(config_json, encoding="utf-8"))
    except Exception:
        config = None
if config is None and os.path.exists(config_conf):
    cfg = {}
    with open(config_conf, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^([A-Z_]+)="?([^"]*)"?$', line.strip())
            if m: cfg[m.group(1)] = m.group(2)
    config = {
        "backend":  {"dir": cfg.get("BACKEND_DIR", ""),  "stack": cfg.get("BACKEND_STACK", "")},
        "frontend": {"dir": cfg.get("FRONTEND_DIR", ""), "stack": cfg.get("FRONTEND_STACK", "")},
        "workflow": {"max_retry": int(cfg.get("MAX_RETRY", "3"))},
        "paths":    {"signals": ".aiagents/signals", "logs": ".aiagents/logs",
                     "state": ".aiagents/state", "memory": ".aiagents/memory",
                     "specs": "docs/ai-agents/specs", "reviews": "docs/ai-agents/reviews",
                     "retrospectives": "docs/ai-agents/retrospectives"}
    }
if config is None:
    config = {"backend": {"dir": "", "stack": ""}, "frontend": {"dir": "", "stack": ""},
              "workflow": {}, "paths": {"signals": ".aiagents/signals"}}

sig = os.path.join(root, config["paths"].get("signals", ".aiagents/signals"))

def state(agent):
    for fn, value in [
        (f"task_ready_{agent}", "queued"),
        (f"bugfix_{agent}", "queued-bugfix"),
        (f"{agent}_done", "done-awaiting-review"),
        (f"{agent}_failed", "failed"),
        (f"{agent}_timeout", "timeout"),
    ]:
        if os.path.exists(os.path.join(sig, fn)):
            return value
    return "idle"

def worker_state(agent):
    workers_path = os.path.join(runtime_dir, "workers.json")
    heartbeat_path = os.path.join(runtime_dir, "heartbeats", f"{agent}.json")
    try:
        workers = json.load(open(workers_path, encoding="utf-8"))
        entry = dict(workers.get(agent) or {})
    except Exception:
        entry = {}
    try:
        heartbeat = json.load(open(heartbeat_path, encoding="utf-8"))
        entry["last_heartbeat"] = heartbeat.get("updated_at")
        hb_time = datetime.datetime.fromisoformat(entry["last_heartbeat"])
        if (now - hb_time).total_seconds() > 10 and entry.get("status") == "running":
            entry["status"] = "stale"
    except Exception:
        if entry.get("status") == "running":
            entry["status"] = "stale"
    if not entry:
        entry = {"status": "stopped"}
    return entry

snapshot = {
    "updated_at": now.isoformat(),
    "project_root": root,
    "backend":  {"dir": config["backend"].get("dir", ""),  "stack": config["backend"].get("stack", ""),  "state": state("backend")},
    "frontend": {"dir": config["frontend"].get("dir", ""), "stack": config["frontend"].get("stack", ""), "state": state("frontend")},
    "workers":  {"backend": worker_state("backend"), "frontend": worker_state("frontend")},
    "workflow": config.get("workflow", {}),
    "paths":    config.get("paths", {}),
}
os.makedirs(state_dir, exist_ok=True)
open(os.path.join(state_dir, "current.json"), "w", encoding="utf-8").write(
    json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n")
PY
}

event() {
  local agent="$1" status="$2" message="$3"
  "$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$agent" "$status" "$message" <<'PY'
import json, os, sys, datetime
path, agent, status, message = sys.argv[1:5]
os.makedirs(os.path.dirname(path), exist_ok=True)
record = {
    "time": datetime.datetime.now().astimezone().isoformat(),
    "agent": agent,
    "status": status,
    "message": message,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY
  write_state
}

# ---------- spec 路径解析 ----------
spec_path() {
  case "$1" in
    backend)
      if [ -f "$SPEC_DIR/02-后端编码.md" ]; then echo "$SPEC_DIR/02-后端编码.md"
      else echo "$SPEC_DIR/02-backend.md"; fi ;;
    frontend)
      if [ -f "$SPEC_DIR/03-前端编码.md" ]; then echo "$SPEC_DIR/03-前端编码.md"
      else echo "$SPEC_DIR/03-frontend.md"; fi ;;
    bugfix-backend)
      if [ -f "$SPEC_DIR/04-Bug修复-backend.md" ]; then echo "$SPEC_DIR/04-Bug修复-backend.md"
      else echo "$SPEC_DIR/04-bugfix-backend.md"; fi ;;
    bugfix-frontend)
      if [ -f "$SPEC_DIR/04-Bug修复-frontend.md" ]; then echo "$SPEC_DIR/04-Bug修复-frontend.md"
      else echo "$SPEC_DIR/04-bugfix-frontend.md"; fi ;;
    *) echo "未知目标: $1" >&2; exit 2 ;;
  esac
}

signal_path() {
  case "$1" in
    backend) echo "$SIG_DIR/task_ready_backend" ;;
    frontend) echo "$SIG_DIR/task_ready_frontend" ;;
    bugfix-backend) echo "$SIG_DIR/bugfix_backend" ;;
    bugfix-frontend) echo "$SIG_DIR/bugfix_frontend" ;;
    *) echo "未知目标: $1" >&2; exit 2 ;;
  esac
}

dispatch_agent() {
  local kind="$1" spec signal
  spec="$(spec_path "$kind")"
  signal="$(signal_path "$kind")"
  [ -f "$spec" ] || { echo "派发失败,规格文件不存在: $spec" >&2; exit 3; }
  "$PYTHON_BIN" - "$kind" "$spec" "$signal" <<'PY'
import json, sys, datetime
kind, spec, signal = sys.argv[1:4]
payload = {
    "kind": kind,
    "spec": spec,
    "dispatched_at": datetime.datetime.now().astimezone().isoformat(),
}
open(signal, "w", encoding="utf-8").write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
  event "$kind" "dispatched" "任务已派发: $(basename "$spec")"
  echo "✅ 已派发 $kind"
  echo "   信号: $signal"
  echo "   spec: $spec"
}

# ---------- wait ----------
consume_signal() {
  local file="$1" name ts
  name="$(basename "$file")"
  ts="$(date +%Y%m%d_%H%M%S)"
  mv "$file" "$SIG_DIR/.consumed_${name}_${ts}" 2>/dev/null || rm -f "$file"
}

wait_agent() {
  local agent="$1" max="$2" start elapsed suffix file reason
  start="$(date +%s)"
  echo "⏳ 等待 Codex-$agent 完成信号(最长 ${max}s)..."
  while true; do
    elapsed=$(( $(date +%s) - start ))
    for suffix in done failed timeout; do
      file="$SIG_DIR/${agent}_${suffix}"
      if [ -f "$file" ]; then
        reason=""
        [ "$suffix" = done ] || reason="$(head -c 400 "$file" 2>/dev/null | tr '\n' ' ')"
        consume_signal "$file"
        event "$agent" "$suffix" "检测到 ${agent}_${suffix}"
        case "$suffix" in
          done) echo ""; echo "✅ $agent 完成"; exit 0 ;;
          failed) echo ""; echo "❌ FAILED: $reason"; exit 1 ;;
          timeout) echo ""; echo "⏰ TIMEOUT: $reason"; exit 2 ;;
        esac
      fi
    done
    if [ "$elapsed" -ge "$max" ]; then
      event "$agent" "wait-expired" "等待 ${max}s 超时但未收到信号"
      echo ""
      echo "⚠️ 等待 ${max}s 仍无信号 — Codex 可能仍在运行(Stop hook 兜底)"
      exit 3
    fi
    printf "\r  ⏳ %3ds / %ds  " "$elapsed" "$max"
    sleep 3
  done
}

# ---------- status / memory ----------
show_status() {
  write_state
  echo "=========================================="
  echo "  ai-agents-kit 状态 · $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  if [ -f "$STATE_DIR/current.json" ]; then
    "$PYTHON_BIN" - "$STATE_DIR/current.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
def fmt_state(s):
    return {
        "idle": "💤 空闲",
        "queued": "⏳ 队列中",
        "queued-bugfix": "🔧 修复队列中",
        "running": "🚀 进行中",
        "done-awaiting-review": "✅ 已完成,待审查",
        "failed": "❌ 失败",
        "timeout": "⏰ 超时",
    }.get(s, s)
for agent in ("backend", "frontend"):
    a = data[agent]
    w = data["workers"][agent]
    print(f"【{agent}】 dir={a['dir']} stack={a['stack']}")
    print(f"   状态: {fmt_state(a['state'])}")
    print(f"   worker: {w.get('status','stopped')} pid={w.get('pid','-')} hb={w.get('last_heartbeat','-')}")
PY
  fi
  echo
  for abbr in be fe; do
    latest="$(ls -1t "$LOG_DIR"/${abbr}_*.log 2>/dev/null | head -1 || true)"
    if [ -n "$latest" ] && [ -f "$latest" ]; then
      name="$(basename "$latest")"
      [ "$abbr" = be ] && label="Backend" || label="Frontend"
      echo "--- $label · $name 尾 15 行 ---"
      tail -15 "$latest"
      echo
    fi
  done
  echo "状态: $STATE_DIR/current.json"
  echo "事件: $STATE_DIR/events.jsonl"
}

add_memory() {
  local text="$1" path="$MEMORY_DIR/global/patterns.md"
  [ -n "$text" ] || { echo "请提供要写入的经验文本" >&2; exit 2; }
  [ -f "$path" ] || printf '# 成功模式 (Patterns)\n\n' > "$path"
  {
    printf '\n## %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
    printf -- '- %s\n' "$text"
  } >> "$path"
  event "memory" "captured" "写入记忆"
  echo "✅ 已写入 $path"
}

case "$COMMAND" in
  status) show_status ;;
  dispatch) dispatch_agent "$TARGET" ;;
  wait) wait_agent "$TARGET" "$WAIT_SECONDS" ;;
  watch) bash "$BIN_DIR/watch-agent.sh" "$TARGET" ;;
  memory) add_memory "$TARGET" ;;
  *) echo "用法: agentctl.sh {status|dispatch|wait|watch|memory} [target] [seconds]" >&2; exit 2 ;;
esac
