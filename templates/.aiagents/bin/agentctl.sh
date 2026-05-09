#!/usr/bin/env bash
# ai-agents-kit v2: Bash 控制入口。
#
# 用法:
#   bash agentctl.sh status                                        # 查状态(刷 state/current.json + 日志尾部)
#   bash agentctl.sh dispatch [--provider X] [--timeout N] <kind>  # 派发任务(backend|frontend|bugfix-backend|bugfix-frontend)
#   bash agentctl.sh wait backend [seconds]                        # 阻塞等待 done/failed/timeout
#   bash agentctl.sh watch backend                                 # 启动 watcher(交给 watch-agent.sh)
#   bash agentctl.sh memory "经验文本"                            # 写一条记忆到 memory/global/patterns.md
#   bash agentctl.sh release-without-verify <agent> "<reason>"    # 强制跳过验证,直接设置 ready-for-human

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

# Read existing state to preserve special states
existing_state = {}
existing_path = os.path.join(state_dir, "current.json")
if os.path.exists(existing_path):
    try:
        existing_data = json.load(open(existing_path, encoding="utf-8"))
        for ag in ("backend", "frontend"):
            if ag in existing_data:
                existing_state[ag] = existing_data[ag].get("state", "idle")
    except Exception:
        pass

PRESERVED_STATES = {"claude-verifying", "ready-for-human"}

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
    # No signal matches — preserve special states from existing state.json
    prev = existing_state.get(agent, "idle")
    if prev in PRESERVED_STATES:
        return prev
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

# ---------- provider 验证 ----------
# validate_provider <provider> — exit 2 if provider block exists and provider is unknown
# If no providers block found, warns but allows through (graceful fallback for v2 configs)
validate_provider() {
  local provider="$1"
  "$PYTHON_BIN" - "$CONFIG_JSON" "$provider" <<'PY'
import json, os, sys
config_json, provider = sys.argv[1], sys.argv[2]
if not os.path.exists(config_json):
    # No config.json at all — warn but allow through (exit 10 = "soft fail")
    print(f"Warning: no config.json found; cannot validate provider '{provider}' (no providers block found OR '{provider}' not configured)", file=sys.stderr)
    sys.exit(10)
try:
    config = json.load(open(config_json, encoding="utf-8"))
except Exception:
    print(f"Warning: failed to parse {config_json}; cannot validate provider '{provider}'", file=sys.stderr)
    sys.exit(10)
providers = config.get("providers", None)
if providers is None:
    # No providers block — warn but allow through
    print(f"Warning: config.json has no 'providers' block; no providers block found OR '{provider}' not configured", file=sys.stderr)
    sys.exit(10)
# Providers block exists — strict validation
if isinstance(providers, dict):
    available = list(providers.keys())
elif isinstance(providers, list):
    available = providers
else:
    available = []
if provider not in available:
    print(f"Error: unknown provider '{provider}'. Available: {', '.join(available) if available else '(none configured)'}", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
PY
  local rc=$?
  # rc=2: providers block exists but provider not found — hard error
  if [ "$rc" -eq 2 ]; then
    exit 2
  fi
  # rc=10: no providers block — warned, allow through
  # rc=0: valid
  return 0
}

dispatch_agent() {
  local kind="$1" provider_override="${2:-}" timeout_override="${3:-}" spec signal
  spec="$(spec_path "$kind")"
  signal="$(signal_path "$kind")"
  [ -f "$spec" ] || { echo "派发失败,规格文件不存在: $spec" >&2; exit 3; }
  "$PYTHON_BIN" - "$kind" "$spec" "$signal" "$provider_override" "$timeout_override" <<'PY'
import json, sys, datetime
kind, spec, signal, provider_override, timeout_override = sys.argv[1:6]
payload = {
    "kind": kind,
    "spec": spec,
    "dispatched_at": datetime.datetime.now().astimezone().isoformat(),
    "provider_override": provider_override,
    "timeout_override": timeout_override,
}
open(signal, "w", encoding="utf-8").write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
  event "$kind" "dispatched" "任务已派发: $(basename "$spec")"
  echo "dispatched $kind"
  echo "   信号: $signal"
  echo "   spec: $spec"
  [ -n "$provider_override" ] && echo "   provider: $provider_override"
  [ -n "$timeout_override" ] && echo "   timeout: ${timeout_override}s"
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
  echo "waiting Codex-$agent (max ${max}s)..."
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
          done) echo ""; echo "$agent done"; exit 0 ;;
          failed) echo ""; echo "FAILED: $reason"; exit 1 ;;
          timeout) echo ""; echo "TIMEOUT: $reason"; exit 2 ;;
        esac
      fi
    done
    if [ "$elapsed" -ge "$max" ]; then
      event "$agent" "wait-expired" "等待 ${max}s 超时但未收到信号"
      echo ""
      echo "wait ${max}s no signal — Codex may still be running (Stop hook fallback)"
      exit 3
    fi
    printf "\r  %3ds / %ds  " "$elapsed" "$max"
    sleep 3
  done
}

# ---------- status / memory ----------
show_status() {
  write_state
  echo "=========================================="
  echo "  ai-agents-kit status · $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  if [ -f "$STATE_DIR/current.json" ]; then
    "$PYTHON_BIN" - "$STATE_DIR/current.json" "$CONFIG_JSON" <<'PY'
import json, os, sys
state_file, config_json = sys.argv[1], sys.argv[2]
data = json.load(open(state_file, encoding="utf-8"))

# Load config for provider lookup
config = {}
if os.path.exists(config_json):
    try:
        config = json.load(open(config_json, encoding="utf-8"))
    except Exception:
        config = {}

def get_provider(agent):
    # Try agents.<agent>.provider → default_provider → "codex"
    agents_cfg = config.get("agents", {})
    if isinstance(agents_cfg, dict) and agent in agents_cfg:
        p = agents_cfg[agent].get("provider", "")
        if p:
            return p
    dp = config.get("default_provider", "")
    if dp:
        return dp
    return "codex"

def fmt_state(s):
    return {
        "idle": "idle",
        "queued": "queued",
        "queued-bugfix": "queued-bugfix",
        "running": "running",
        "done-awaiting-review": "done-awaiting-review",
        "failed": "failed",
        "timeout": "timeout",
        "claude-verifying": "claude-verifying",
        "ready-for-human": "ready-for-human",
    }.get(s, s)

for agent in ("backend", "frontend"):
    a = data[agent]
    w = data["workers"][agent]
    provider = get_provider(agent)
    print(f"[{agent}] dir={a['dir']} stack={a['stack']}")
    print(f"   state: {fmt_state(a['state'])}")
    print(f"   provider: {provider}")
    print(f"   worker: {w.get('status','stopped')} pid={w.get('pid','-')} hb={w.get('last_heartbeat','-')}")
PY
  fi
  echo
  for abbr in be fe; do
    latest="$(ls -1t "$LOG_DIR"/${abbr}_*.log 2>/dev/null | head -1 || true)"
    if [ -n "$latest" ] && [ -f "$latest" ]; then
      name="$(basename "$latest")"
      [ "$abbr" = be ] && label="Backend" || label="Frontend"
      echo "--- $label · $name tail 15 ---"
      tail -15 "$latest"
      echo
    fi
  done
  echo "state: $STATE_DIR/current.json"
  echo "events: $STATE_DIR/events.jsonl"
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
  echo "written to $path"
}

# ---------- release-without-verify ----------
release_without_verify() {
  local agent="${1:-}" reason="${2:-}"
  [ -n "$agent" ] || { echo "用法: agentctl.sh release-without-verify <backend|frontend> \"<reason>\"" >&2; exit 2; }
  [ -n "$reason" ] || { echo "用法: agentctl.sh release-without-verify <backend|frontend> \"<reason>\"" >&2; exit 2; }
  case "$agent" in
    backend|frontend) ;;
    *) echo "未知 agent: $agent (必须是 backend 或 frontend)" >&2; exit 2 ;;
  esac

  # 1. Edit state/current.json: set agent.state = "ready-for-human"
  "$PYTHON_BIN" - "$STATE_DIR/current.json" "$agent" <<'PY'
import json, os, sys, datetime
state_file, agent = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(state_file), exist_ok=True)
if os.path.exists(state_file):
    try:
        data = json.load(open(state_file, encoding="utf-8"))
    except Exception:
        data = {}
else:
    data = {}
if agent not in data:
    data[agent] = {}
data[agent]["state"] = "ready-for-human"
data["updated_at"] = datetime.datetime.now().astimezone().isoformat()
open(state_file, "w", encoding="utf-8").write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY

  # 2. Append event to events.jsonl with phase=verify-bypassed
  "$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$agent" "$reason" <<'PY'
import json, os, sys, datetime
events_file, agent, reason = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(events_file), exist_ok=True)
record = {
    "time": datetime.datetime.now().astimezone().isoformat(),
    "agent": agent,
    "phase": "verify-bypassed",
    "status": "ready-for-human",
    "reason": reason,
    "by": "lane",
}
with open(events_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY

  # 3. Append to bugs.md if it exists
  local bugs_md="$MEMORY_DIR/global/bugs.md"
  if [ -f "$bugs_md" ]; then
    local ts
    ts="$(date '+%Y-%m-%d %H:%M')"
    {
      printf '\n## %s · verify-bypass: %s\n\n' "$ts" "$agent"
      printf '**触发**: `/release-without-verify %s "%s"` 显式破例\n' "$agent" "$reason"
      printf '**reason**: %s\n' "$reason"
      printf '**待补**: 后续阶段 review 时核对该轮是否有遗漏 bug\n'
    } >> "$bugs_md"
  fi

  echo "released without verify: agent=$agent reason=$reason"
}

case "$COMMAND" in
  status) show_status ;;
  dispatch)
    # Parse optional --provider and --timeout flags, then <kind>
    _dispatch_provider=""
    _dispatch_timeout=""
    _dispatch_kind=""
    shift  # remove "dispatch" from positional params; remaining are $@
    while [ $# -gt 0 ]; do
      case "$1" in
        --provider)
          shift
          [ $# -gt 0 ] || { echo "Error: --provider requires an argument" >&2; exit 2; }
          _dispatch_provider="$1"
          shift
          ;;
        --timeout)
          shift
          [ $# -gt 0 ] || { echo "Error: --timeout requires an argument" >&2; exit 2; }
          _dispatch_timeout="$1"
          shift
          ;;
        -*)
          echo "Error: unknown flag '$1'" >&2; exit 2
          ;;
        *)
          if [ -n "$_dispatch_kind" ]; then
            echo "Error: unexpected argument '$1' (kind already set to '$_dispatch_kind')" >&2; exit 2
          fi
          _dispatch_kind="$1"
          shift
          ;;
      esac
    done
    [ -n "$_dispatch_kind" ] || { echo "Error: dispatch requires <kind>: backend|frontend|bugfix-backend|bugfix-frontend" >&2; exit 2; }
    # Validate provider if specified
    if [ -n "$_dispatch_provider" ]; then
      validate_provider "$_dispatch_provider"
    fi
    dispatch_agent "$_dispatch_kind" "$_dispatch_provider" "$_dispatch_timeout"
    ;;
  wait) wait_agent "$TARGET" "$WAIT_SECONDS" ;;
  watch) bash "$BIN_DIR/watch-agent.sh" "$TARGET" ;;
  memory) add_memory "$TARGET" ;;
  release-without-verify)
    release_without_verify "${2:-}" "${3:-}"
    ;;
  *) echo "用法: agentctl.sh {status|dispatch|wait|watch|memory|release-without-verify} [args]" >&2; exit 2 ;;
esac
