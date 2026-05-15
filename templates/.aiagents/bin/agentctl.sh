#!/usr/bin/env bash
# ai-agents-kit v2: Bash 控制入口。
#
# 用法:
#   bash agentctl.sh up                                            # 一键起 backend + frontend watcher (后台 + disown)
#   bash agentctl.sh down                                          # 一键停所有 watcher
#   bash agentctl.sh restart                                       # down + up
#   bash agentctl.sh status                                        # 查状态(刷 state/current.json + 日志尾部)
#   bash agentctl.sh logs                                          # 列所有日志路径 + 末尾快照(不 follow)
#   bash agentctl.sh logs <agent> [pretty|worker|raw]              # tail -F 单个日志(默认 pretty)
#   bash agentctl.sh logs both                                     # tail -F backend + frontend pretty
#   bash agentctl.sh dispatch [--provider X] [--timeout N] [--model M] <kind>  # 派发任务(backend|frontend|bugfix-backend|bugfix-frontend)
#                                # --model: 单次覆盖 claude/codex CLI 的 --model 参数 (e.g. opus|sonnet|haiku)
#   bash agentctl.sh wait backend [seconds]                        # 阻塞等待 done/failed/timeout
#   bash agentctl.sh watch backend                                 # 启动单个 watcher (前台,通常由 up 子命令后台调)
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

def _proc_alive(pid):
    if pid <= 0:
        return False
    # POSIX 优先(Linux / macOS / MSYS bash 也支持 os.kill,但 Windows 原生 Python 报 WinError 87)
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        pass  # Windows: fallback subprocess kill -0(MSYS bash 必有 kill)
    try:
        import subprocess
        return subprocess.run(
            ["kill", "-0", str(pid)], capture_output=True, check=False, timeout=2
        ).returncode == 0
    except Exception:
        return False

def state(agent):
    # v3.4 framework fix: running lock 优先(由 agent-runner.sh 写,编码 agent 真在跑时 state="running")
    lock_path = os.path.join(runtime_dir, f"{agent}.running.lock")
    if os.path.exists(lock_path):
        try:
            pid = int(open(lock_path, encoding="utf-8").read().strip())
            if pid > 0 and _proc_alive(pid):
                return "running"
            # lock 进程已死 → 当 stale lock 处理(rm 让后续逻辑接管)
            os.remove(lock_path)
        except Exception:
            pass
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

def agent_provider(agent):
    """Resolve provider for given agent: agents.<a>.provider → default_provider → codex."""
    try:
        agents_block = config.get("agents") or {}
        ag = agents_block.get(agent) or {}
        if ag.get("provider"):
            return ag["provider"]
    except Exception:
        pass
    return config.get("default_provider") or "codex"

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

# Resolve agent dir/stack from new schema (agents.<a>.dir) with v2 fallback (top-level <a>.dir)
def agent_field(agent, key):
    try:
        ab = config.get("agents") or {}
        if agent in ab and ab[agent].get(key) is not None:
            return ab[agent].get(key, "")
    except Exception:
        pass
    return (config.get(agent) or {}).get(key, "")

snapshot = {
    "updated_at": now.isoformat(),
    "project_root": root,
    "backend":  {"dir": agent_field("backend", "dir"),  "stack": agent_field("backend", "stack"),  "provider": agent_provider("backend"),  "state": state("backend")},
    "frontend": {"dir": agent_field("frontend", "dir"), "stack": agent_field("frontend", "stack"), "provider": agent_provider("frontend"), "state": state("frontend")},
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
  local agent="$1" status="$2" message="$3" provider="${4:-}"
  "$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$agent" "$status" "$message" "$provider" <<'PY'
import json, os, sys, datetime
path, agent, status, message, provider = sys.argv[1:6]
os.makedirs(os.path.dirname(path), exist_ok=True)
record = {
    "time": datetime.datetime.now().astimezone().isoformat(),
    "agent": agent,
    "status": status,
    "message": message,
}
if provider:
    record["provider"] = provider
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
  local kind="$1" provider_override="${2:-}" timeout_override="${3:-}" model_override="${4:-}" spec signal
  spec="$(spec_path "$kind")"
  signal="$(signal_path "$kind")"
  [ -f "$spec" ] || { echo "派发失败,规格文件不存在: $spec" >&2; exit 3; }
  "$PYTHON_BIN" - "$kind" "$spec" "$signal" "$provider_override" "$timeout_override" "$model_override" <<'PY'
import json, sys, datetime
kind, spec, signal, provider_override, timeout_override, model_override = sys.argv[1:7]
payload = {
    "kind": kind,
    "spec": spec,
    "dispatched_at": datetime.datetime.now().astimezone().isoformat(),
    "provider_override": provider_override,
    "timeout_override": timeout_override,
    "model_override": model_override,
}
open(signal, "w", encoding="utf-8").write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
  event "$kind" "dispatched" "任务已派发: $(basename "$spec")"
  echo "dispatched $kind"
  echo "   信号: $signal"
  echo "   spec: $spec"
  [ -n "$provider_override" ] && echo "   provider: $provider_override"
  [ -n "$timeout_override" ] && echo "   timeout: ${timeout_override}s"
  [ -n "$model_override" ] && echo "   model: $model_override"
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
  echo "waiting $agent (max ${max}s)..."
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
      echo "wait ${max}s no signal — coding agent may still be running (Stop hook fallback)"
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

# ---------- retry-other-provider ----------
# Generates handover.md skeleton from events.jsonl + git log, prompts main Claude to fill ✅/❌ then dispatch对家.
retry_other_provider() {
  local agent="${1:-}"
  [ -n "$agent" ] || { echo "用法: agentctl.sh retry-other-provider <backend|frontend>" >&2; exit 2; }
  case "$agent" in backend|frontend) ;; *) echo "未知 agent: $agent" >&2; exit 2 ;; esac

  # Read events.jsonl末尾 to find prev provider + failure reason
  local prev_provider fail_reason
  read -r prev_provider fail_reason < <("$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$agent" <<'PY'
import json, sys
path, agent = sys.argv[1:3]
prev_provider, fail_reason = "", ""
try:
    with open(path, encoding='utf-8') as f:
        for line in f:
            try:
                rec = json.loads(line)
                if rec.get("agent") == agent:
                    if rec.get("provider"):
                        prev_provider = rec["provider"]
                    if rec.get("status") in ("failed", "timeout", "stale"):
                        fail_reason = rec.get("message", "") or rec.get("reason", "")
            except Exception: pass
except Exception: pass
print(prev_provider, fail_reason)
PY
)
  [ -n "$prev_provider" ] || { echo "未找到 $agent 上次使用的 provider (events.jsonl 无记录)" >&2; exit 2; }

  # Find another provider from config.providers
  local other_provider
  other_provider="$("$PYTHON_BIN" - "$CONFIG_JSON" "$prev_provider" <<'PY'
import json, sys
cfg, prev = sys.argv[1:3]
try:
    d = json.load(open(cfg, encoding='utf-8'))
    others = [k for k in (d.get("providers") or {}).keys() if k != prev]
    print(others[0] if others else "")
except Exception:
    print("")
PY
)"
  [ -n "$other_provider" ] || { echo "config.json providers 仅含 $prev_provider,无可切换的另一家" >&2; exit 2; }

  # Resolve agent dir
  local work_dir
  work_dir="$("$PYTHON_BIN" - "$CONFIG_JSON" "$agent" <<'PY'
import json, sys
cfg, agent = sys.argv[1:3]
try:
    d = json.load(open(cfg, encoding='utf-8'))
    ab = d.get("agents") or {}
    print((ab.get(agent) or {}).get("dir") or (d.get(agent) or {}).get("dir") or "")
except Exception:
    print("")
PY
)"
  local work_abs="$ROOT/$work_dir"
  [ -d "$work_abs" ] || { echo "agent 工作目录不存在: $work_abs" >&2; exit 2; }

  local commits_list status_out
  commits_list="$(cd "$work_abs" && git log --oneline HEAD --pretty=format:"  - %h %s" -10 2>/dev/null | head -10)"
  status_out="$(cd "$work_abs" && git status --porcelain 2>/dev/null | sed 's/^/  /')"

  mkdir -p "$RUNTIME_DIR"
  local handover="$RUNTIME_DIR/${agent}-handover.md"
  cat > "$handover" <<EOF
# Handover: $agent 接续派单 (provider $prev_provider → $other_provider)

**触发**: 主 Claude 决定换 provider,前一家 $prev_provider 失败 ($fail_reason)

## 前一轮已落

- 自上次 dispatch 起的 commits:
$commits_list

- 未 commit 改动:
$status_out

## Spec 验收清单逐项状态

> **主 Claude 待填**: 跑 spec § 自检 grep 矩阵后填 ✅/❌(每条验收点)
> 例:
> - ✅ §1 字段 X 已实现 (file.py:42)
> - ❌ §3 测试覆盖 Z (pytest tests/test_z.py 仍 NotImplementedError)

(待填)

## 续做要求(硬约束)

1. 基于当前 working tree 状态续做,**不重写** ✅ 状态的模块
2. 优先补齐 ❌ 状态的验收点(按上序逐项推进)
3. 如发现前一轮某 ✅ 模块写错,单独 commit 修(commit message 含 "fix prev round")
4. commit 不覆盖前一轮历史 — 新 commit 在 HEAD 上叠加(禁 git reset / amend / push -f)

## 原 spec 在下一段
EOF

  event "$agent" "handover-skeleton" "生成 handover 骨架: $prev_provider → $other_provider" "$prev_provider"

  echo "✅ 已生成 handover 骨架: $handover"
  echo ""
  echo "next steps (主 Claude):"
  echo "  1. 跑 spec § 自检 grep 矩阵填 ## Spec 验收清单逐项状态 段"
  echo "  2. 调 /dispatch-${agent} --provider $other_provider (或 /bugfix-${agent} --provider $other_provider)"
  echo ""
  echo "派单成功后 handover.md 自动归档到 runtime/archive/"
}

# ---------- v3.2 一键启停 (up/down/restart) ----------
# 痛点: 冷启动每次敲 200 字符的 nohup ... & disown 双行,反人类。
# 设计:
#   - up 起两个 watcher (background + nohup + disown),pid 取 $! 立即记录
#   - 已在跑则跳过(workers.json + kill -0 双重确认,防 stale pid 误判)
#   - down 从 workers.json 读 pid,kill 后清状态
#   - 兼容 git-bash on Windows: nohup / disown / & 都可用,但 Windows 关 git-bash
#     窗口可能带走子进程,提示用户用 PowerShell agentctl.ps1 等价命令获得真后台

_get_alive_worker_pid() {
  # echoes pid if workers.json has one and process is alive; otherwise empty.
  local agent="$1" pid=""
  [ -f "$RUNTIME_DIR/workers.json" ] || return 0
  pid="$("$PYTHON_BIN" -c "
import json
try:
    d = json.load(open(r'$RUNTIME_DIR/workers.json', encoding='utf-8'))
    p = (d.get('$agent') or {}).get('pid')
    if p: print(p)
except Exception:
    pass
" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

watchers_up() {
  local started=0 already=0
  for agent in backend frontend; do
    local log="$LOG_DIR/worker-${agent}.log"
    local pid
    pid="$(_get_alive_worker_pid "$agent")"
    if [ -n "$pid" ]; then
      echo "ℹ️  $agent watcher 已在跑 (pid=$pid, log=$log) — 跳过"
      already=$((already+1))
      continue
    fi
    nohup bash "$BIN_DIR/watch-agent.sh" "$agent" > "$log" 2>&1 < /dev/null &
    local new_pid=$!
    disown 2>/dev/null || true
    echo "✅ $agent watcher 启动 pid=$new_pid · log=$log"
    started=$((started+1))
  done
  echo ""
  echo "总计: $started 个新启动 / $already 个已在跑"
  if [ "$started" -gt 0 ]; then
    echo "提示: bash $BIN_DIR/agentctl.sh status 可查实时状态;Ctrl+C 不影响后台 watcher"
  fi
}

# ---------- v3.2.1 日志监控 (logs) ----------
# 痛点: up 后 watcher / agent-runner 全后台,Lane 看不到实时执行。
# 设计:
#   - 无参数: 打印所有日志路径 + 末尾 5 行快照(像 status 但只关注日志)
#   - logs <agent>: tail -F 当前 pretty log (codex/claude 实时输出)
#   - logs <agent> worker: tail -F watcher 自己的 stdout (检测 watcher 是否还活着)
#   - logs <agent> raw: tail -F claude 原始 JSON Lines (v3.0.2+ 双 log debug)
#   - logs both: tail -F backend + frontend pretty (合并视图,GNU tail 自带 banner)

_log_path_for() {
  local agent="$1" kind="${2:-pretty}"
  local abbr="be"; [ "$agent" = "frontend" ] && abbr="fe"
  local today
  today="$(date +%Y%m%d)"
  case "$kind" in
    pretty) echo "$LOG_DIR/${abbr}_${today}.log" ;;
    worker) echo "$LOG_DIR/worker-${agent}.log" ;;
    raw)    echo "$LOG_DIR/${abbr}_${today}.log.raw" ;;
    *)      echo "" ;;
  esac
}

logs_snapshot() {
  echo "==========================================="
  echo "  日志路径 + 末尾快照 (logs <agent> 可 follow)"
  echo "==========================================="
  for agent in backend frontend; do
    local abbr="be"; [ "$agent" = "frontend" ] && abbr="fe"
    echo ""
    echo "[$agent]"
    for kind in pretty worker raw; do
      local p
      p="$(_log_path_for "$agent" "$kind")"
      if [ -f "$p" ]; then
        local size
        size="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
        printf "  %-7s %s (%s bytes)\n" "$kind:" "$p" "$size"
      else
        printf "  %-7s %s (不存在)\n" "$kind:" "$p"
      fi
    done
    # snapshot pretty 末尾 5 行
    local pp
    pp="$(_log_path_for "$agent" pretty)"
    if [ -f "$pp" ]; then
      echo "  --- pretty 尾 5 行 ---"
      tail -5 "$pp" 2>/dev/null | sed 's/^/    /'
    fi
  done
  echo ""
  echo "follow 用法:"
  echo "  bash $BIN_DIR/agentctl.sh logs backend           # 跟 backend pretty"
  echo "  bash $BIN_DIR/agentctl.sh logs frontend          # 跟 frontend pretty"
  echo "  bash $BIN_DIR/agentctl.sh logs both              # 双 agent 同时跟"
  echo "  bash $BIN_DIR/agentctl.sh logs backend worker    # 跟 watcher 自身输出"
  echo "  bash $BIN_DIR/agentctl.sh logs backend raw       # 跟 claude 原始 JSON"
}

# logs follow 默认过滤 stream-json 残留行 (^{") — 历史 v3.0.1 log 或 raw 误传都不会刷屏
# LOGS_NOFILTER=1 可禁用过滤 (debug 时看完整内容)
_logs_filter() {
  if [ "${LOGS_NOFILTER:-0}" = "1" ]; then
    cat
  else
    # 过滤以 { 开头的行 (stream-json Lines 都以 {"type":..., {"subtype":... 开头)
    grep --line-buffered -v '^{' || cat
  fi
}

logs_follow() {
  local agent="$1" kind="${2:-pretty}"
  if [ "$agent" = "both" ] || [ "$agent" = "all" ]; then
    local be fe
    be="$(_log_path_for backend pretty)"
    fe="$(_log_path_for frontend pretty)"
    [ -f "$be" ] || touch "$be"
    [ -f "$fe" ] || touch "$fe"
    echo "tail -F $be $fe (Ctrl+C 退出, 默认过滤 JSON; LOGS_NOFILTER=1 看完整)"
    tail -F "$be" "$fe" | _logs_filter
    return
  fi
  if [ "$agent" != "backend" ] && [ "$agent" != "frontend" ]; then
    echo "用法: agentctl.sh logs {backend|frontend|both} [pretty|worker|raw]" >&2
    exit 2
  fi
  local f
  f="$(_log_path_for "$agent" "$kind")"
  if [ -z "$f" ]; then
    echo "kind 必须是 pretty|worker|raw,得到: $kind" >&2
    exit 2
  fi
  if [ ! -f "$f" ]; then
    echo "日志暂不存在,等待第一次写入 ($f)..."
    touch "$f"
  fi
  # raw kind 故意不过滤(用户明确想看原始 JSON);worker 也不过滤(本来就是 watcher echo)
  if [ "$kind" = "pretty" ]; then
    echo "tail -F $f (Ctrl+C 退出, 默认过滤 JSON; LOGS_NOFILTER=1 看完整)"
    tail -F "$f" | _logs_filter
  else
    echo "tail -F $f (Ctrl+C 退出, kind=$kind 不过滤)"
    tail -F "$f"
  fi
}

watchers_down() {
  local stopped=0 absent=0
  for agent in backend frontend; do
    local pid
    pid="$(_get_alive_worker_pid "$agent")"
    if [ -z "$pid" ]; then
      echo "ℹ️  $agent: 没有活动的 watcher"
      absent=$((absent+1))
      continue
    fi
    if kill "$pid" 2>/dev/null; then
      sleep 0.3
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
      echo "✅ $agent watcher 已停止 (pid=$pid)"
      stopped=$((stopped+1))
    else
      echo "⚠️  $agent: kill pid=$pid 失败(可能已死)"
    fi
  done
  echo ""
  echo "总计: $stopped 个已停 / $absent 个已无"
}

# ---------- 子命令分派 ----------
case "$COMMAND" in
  up|start) watchers_up ;;
  down|stop) watchers_down ;;
  restart)
    watchers_down
    sleep 0.5
    watchers_up
    ;;
  logs)
    # bash agentctl.sh logs                          → snapshot
    # bash agentctl.sh logs <backend|frontend|both>  → follow
    # bash agentctl.sh logs <agent> <pretty|worker|raw>
    if [ $# -lt 2 ]; then
      logs_snapshot
    else
      logs_follow "${2:-backend}" "${3:-pretty}"
    fi
    ;;
  status) show_status ;;
  dispatch)
    # Parse optional --provider / --timeout / --model flags, then <kind>
    _dispatch_provider=""
    _dispatch_timeout=""
    _dispatch_model=""
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
        --model)
          shift
          [ $# -gt 0 ] || { echo "Error: --model requires an argument (e.g. opus|sonnet|haiku 或完整模型名)" >&2; exit 2; }
          _dispatch_model="$1"
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
    dispatch_agent "$_dispatch_kind" "$_dispatch_provider" "$_dispatch_timeout" "$_dispatch_model"
    ;;
  wait) wait_agent "$TARGET" "$WAIT_SECONDS" ;;
  watch) bash "$BIN_DIR/watch-agent.sh" "$TARGET" ;;
  memory) add_memory "$TARGET" ;;
  release-without-verify)
    release_without_verify "${2:-}" "${3:-}"
    ;;
  retry-other-provider)
    retry_other_provider "${2:-}"
    ;;
  *) echo "用法: agentctl.sh {up|down|restart|status|logs|dispatch|wait|watch|memory|release-without-verify|retry-other-provider} [args]" >&2; exit 2 ;;
esac
