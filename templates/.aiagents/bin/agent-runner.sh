#!/usr/bin/env bash
# ai-agents-kit v2: 统一 Codex 执行入口。
# 调用链: signal -> watch-agent.sh -> agent-runner.sh -> codex -> state/event。
#
# 用法:
#   bash agent-runner.sh <backend|frontend> <task|bugfix>
#
# 设计要点:
# - 唯一 codex 调用点(原版 run-codex.sh 的职责被吸收进来)
# - 写 .aiagents/state/current.json + .aiagents/state/events.jsonl
# - 写 *_done / *_failed / *_timeout 信号
# - 优先用 .aiagents/config.json,缺失时回退到 .claude/agents.conf(KV) — 双格式兼容

set -uo pipefail

AGENT="${1:-backend}"
MODE="${2:-task}"
[ "$AGENT" = backend ] || [ "$AGENT" = frontend ] || { echo "agent 必须是 backend/frontend" >&2; exit 2; }
[ "$MODE" = task ] || [ "$MODE" = bugfix ] || { echo "mode 必须是 task/bugfix" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_JSON="$ROOT/.aiagents/config.json"
CONFIG_CONF="$ROOT/.claude/agents.conf"
SIG_DIR="$ROOT/.aiagents/signals"
STATE_DIR="$ROOT/.aiagents/state"
LOG_DIR="$ROOT/.aiagents/logs"
SPEC_DIR="$ROOT/docs/ai-agents/specs"
BIN_DIR="$ROOT/.aiagents/bin"
RUNTIME_DIR="$ROOT/.aiagents/runtime"
mkdir -p "$SIG_DIR" "$STATE_DIR" "$LOG_DIR" "$RUNTIME_DIR/heartbeats"

PYTHON_BIN=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "pass" >/dev/null 2>&1; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo "缺少可用的 python(注意 Windows 上的 python3 可能是 Store stub),无法处理 JSON 状态" >&2; exit 1; }

# Windows: 强制 Python 使用 UTF-8,避免终端 GBK/CP936 编码导致 emoji 输出报错
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# ---------- 配置读取(双格式) ----------
# 优先 .aiagents/config.json,缺则回退 .claude/agents.conf
config_value() {
  # $1 = json 路径(如 backend.dir),$2 = conf KV 名(如 BACKEND_DIR)
  local jpath="$1" cname="$2" val=""
  if [ -f "$CONFIG_JSON" ]; then
    val="$("$PYTHON_BIN" - "$CONFIG_JSON" "$jpath" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    cur = data
    for part in sys.argv[2].split("."):
        cur = cur[part]
    print(cur)
except Exception:
    pass
PY
)"
  fi
  if [ -z "$val" ] && [ -f "$CONFIG_CONF" ]; then
    val="$(grep -E "^${cname}=" "$CONFIG_CONF" 2>/dev/null | head -1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//')"
  fi
  echo "$val"
}

# resolve_provider <agent>
# Echoes the effective provider name. Resolution order:
#   1. PROVIDER_OVERRIDE env (set by agentctl when --provider passed)
#   2. agents.<agent>.provider in config.json
#   3. default_provider in config.json
#   4. "codex" hardcoded fallback
resolve_provider() {
  local agent="$1"
  if [ -n "${PROVIDER_OVERRIDE:-}" ]; then
    echo "$PROVIDER_OVERRIDE"; return
  fi
  local v
  v="$(config_value "agents.${agent}.provider" "")"
  if [ -n "$v" ]; then echo "$v"; return; fi
  v="$(config_value "default_provider" "")"
  if [ -n "$v" ]; then echo "$v"; return; fi
  echo "codex"
}

WORK_DIR="$(config_value "agents.${AGENT}.dir" "$( [ "$AGENT" = backend ] && echo BACKEND_DIR || echo FRONTEND_DIR )")"
PROVIDER="$(resolve_provider "$AGENT")"
PROVIDER_BIN="$(config_value "providers.${PROVIDER}.bin" "")"
[ -z "$PROVIDER_BIN" ] && PROVIDER_BIN="$PROVIDER"
PROVIDER_ARGS="$(config_value "providers.${PROVIDER}.args" "")"
PROVIDER_SUBCMD="$(config_value "providers.${PROVIDER}.subcommand" "")"
TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE:-$(config_value "providers.${PROVIDER}.timeout" "")}"
[ -z "$TIMEOUT_SECONDS" ] && TIMEOUT_SECONDS="1800"

# v2 fallback: if providers.* block missing, fall back to legacy codex.* for one transition release
if [ -z "$PROVIDER_BIN" ] || { [ "$PROVIDER" = "codex" ] && [ -z "$PROVIDER_ARGS" ]; }; then
  legacy_bin="$(config_value codex.bin CODEX_BIN)"
  legacy_args="$(config_value codex.args CODEX_ARGS)"
  [ -n "$legacy_bin" ] && [ -z "$PROVIDER_BIN" ] && PROVIDER_BIN="$legacy_bin"
  [ -n "$legacy_args" ] && [ -z "$PROVIDER_ARGS" ] && PROVIDER_ARGS="$legacy_args"
fi
[ -z "$PROVIDER_ARGS" ] && [ "$PROVIDER" = "codex" ] && PROVIDER_ARGS="--dangerously-bypass-approvals-and-sandbox"
[ -z "$PROVIDER_ARGS" ] && [ "$PROVIDER" = "claude" ] && PROVIDER_ARGS="--dangerously-skip-permissions"

# ---------- state / event 工具 ----------
write_state() {
  local running_state="$1"
  "$PYTHON_BIN" - "$ROOT" "$AGENT" "$running_state" "$RUNTIME_DIR" "$STATE_DIR" "$CONFIG_JSON" "$CONFIG_CONF" <<'PY'
import json, sys, os, datetime, re
root, agent, running_state, runtime_dir, state_dir, config_json, config_conf = sys.argv[1:8]
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
    config = {"backend": {"dir": "", "stack": ""},
              "frontend": {"dir": "", "stack": ""},
              "workflow": {}, "paths": {"signals": ".aiagents/signals"}}

sig = os.path.join(root, config["paths"].get("signals", ".aiagents/signals"))
def state(name):
    if name == agent:
        return running_state
    for fn, value in [
        (f"task_ready_{name}", "queued"),
        (f"bugfix_{name}", "queued-bugfix"),
        (f"{name}_done", "done-awaiting-review"),
        (f"{name}_failed", "failed"),
        (f"{name}_timeout", "timeout"),
    ]:
        if os.path.exists(os.path.join(sig, fn)):
            return value
    return "idle"

def worker_state(name):
    workers_path = os.path.join(runtime_dir, "workers.json")
    heartbeat_path = os.path.join(runtime_dir, "heartbeats", f"{name}.json")
    try:
        workers = json.load(open(workers_path, encoding="utf-8"))
        entry = dict(workers.get(name) or {})
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
  local status="$1" message="$2"
  "$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" "$status" "$message" "${PROVIDER:-unknown}" <<'PY'
import json, sys, datetime, os
path, agent, status, message, provider = sys.argv[1:6]
os.makedirs(os.path.dirname(path), exist_ok=True)
record = {
    "time": datetime.datetime.now().astimezone().isoformat(),
    "agent": agent,
    "provider": provider,
    "status": status,
    "message": message,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY
}

# ---------- 准备 spec / 工作目录 ----------
if [ "$MODE" = task ]; then
  if [ "$AGENT" = backend ]; then
    SPEC="$SPEC_DIR/02-后端编码.md"
    [ ! -f "$SPEC" ] && [ -f "$SPEC_DIR/02-backend.md" ] && SPEC="$SPEC_DIR/02-backend.md"
  else
    SPEC="$SPEC_DIR/03-前端编码.md"
    [ ! -f "$SPEC" ] && [ -f "$SPEC_DIR/03-frontend.md" ] && SPEC="$SPEC_DIR/03-frontend.md"
  fi
  rm -f "$SIG_DIR/task_ready_$AGENT"
else
  SPEC="$SPEC_DIR/04-Bug修复-$AGENT.md"
  [ ! -f "$SPEC" ] && [ -f "$SPEC_DIR/04-bugfix-$AGENT.md" ] && SPEC="$SPEC_DIR/04-bugfix-$AGENT.md"
  rm -f "$SIG_DIR/bugfix_$AGENT"
fi

[ -f "$SPEC" ] || {
  echo "$AGENT 缺少规格文件: $SPEC" > "$SIG_DIR/${AGENT}_failed"
  event "failed" "缺少规格文件: $SPEC"
  write_state "failed"
  exit 3
}

case "$WORK_DIR" in
  /*|[A-Za-z]:*) WORK_ABS="$WORK_DIR" ;;
  *) WORK_ABS="$ROOT/$WORK_DIR" ;;
esac
[ -d "$WORK_ABS" ] || {
  echo "$AGENT 工作目录不存在: $WORK_ABS" > "$SIG_DIR/${AGENT}_failed"
  event "failed" "工作目录不存在: $WORK_ABS"
  write_state "failed"
  exit 4
}

ABBR="be"; [ "$AGENT" = frontend ] && ABBR="fe"
LOG="$LOG_DIR/${ABBR}_$(date +%Y%m%d).log"

write_state "running"
event "running" "${PROVIDER} 开始执行 spec=$(basename "$SPEC")"

{
  echo
  echo "============================================================"
  echo "agent=$AGENT mode=$MODE provider=$PROVIDER time=$(date -Iseconds)"
  echo "spec=$SPEC"
  echo "work_dir=$WORK_ABS"
  echo "timeout=${TIMEOUT_SECONDS}s"
  echo "============================================================"
} >> "$LOG"

if ! command -v "$PROVIDER_BIN" >/dev/null 2>&1; then
  echo "找不到 provider 可执行文件: $PROVIDER_BIN (provider=$PROVIDER)" | tee -a "$LOG" > "$SIG_DIR/${AGENT}_failed"
  event "failed" "找不到 provider 可执行文件: $PROVIDER_BIN"
  write_state "failed"
  exit 127
fi

# Source adapter for resolved provider
ADAPTER="$BIN_DIR/providers/${PROVIDER}.sh"
if [ ! -f "$ADAPTER" ]; then
  echo "$AGENT 缺少 provider adapter: $ADAPTER (PROVIDER=$PROVIDER)" > "$SIG_DIR/${AGENT}_failed"
  event "failed" "缺少 provider adapter: $PROVIDER"
  write_state "failed"
  exit 5
fi
# shellcheck disable=SC1090
source "$ADAPTER"

# Capture pre-state for evaluate_completion
COMMIT_BEFORE="$(cd "$WORK_ABS" && git rev-parse HEAD 2>/dev/null || echo NONE)"
GIT_STATUS_BEFORE_FILE="$(mktemp)"
(cd "$WORK_ABS" && git status --porcelain 2>/dev/null || true) > "$GIT_STATUS_BEFORE_FILE"

# Build prompt file (preamble + spec) for stdin delivery
PROMPT_FILE="$(mktemp)"
PREAMBLE="$ROOT/.aiagents/prompts/dispatch-preamble.md"
[ -f "$PREAMBLE" ] && cat "$PREAMBLE" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
echo "---" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
cat "$SPEC" >> "$PROMPT_FILE"

# Export env for adapter functions
export PROVIDER_BIN PROVIDER_ARGS PROVIDER_SUBCMD WORK_ABS LOG_FILE="$LOG"

CMD_TEMPLATE="$(provider_build_cmd)"

# ---------- 执行 provider(超时 + 输出过滤) ----------
set +e
if command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC2002
  cat "$PROMPT_FILE" | timeout "$TIMEOUT_SECONDS" bash -c "$CMD_TEMPLATE" 2>&1 | tee -a "$LOG" | bash "$BIN_DIR/filter-output.sh"
else
  # shellcheck disable=SC2002
  cat "$PROMPT_FILE" | bash -c "$CMD_TEMPLATE" 2>&1 | tee -a "$LOG" | bash "$BIN_DIR/filter-output.sh"
fi
rc=${PIPESTATUS[1]}
set -e

# Capture post-state
COMMIT_AFTER="$(cd "$WORK_ABS" && git rev-parse HEAD 2>/dev/null || echo NONE)"
GIT_STATUS_AFTER_FILE="$(mktemp)"
(cd "$WORK_ABS" && git status --porcelain 2>/dev/null || true) > "$GIT_STATUS_AFTER_FILE"

export RC="$rc" LOG_FILE="$LOG" COMMIT_BEFORE COMMIT_AFTER GIT_STATUS_BEFORE_FILE GIT_STATUS_AFTER_FILE
COMPLETION="$(provider_evaluate_completion)"
rm -f "$PROMPT_FILE" "$GIT_STATUS_BEFORE_FILE" "$GIT_STATUS_AFTER_FILE"

case "$COMPLETION" in
  done)
    : > "$SIG_DIR/${AGENT}_done"
    event "done" "${PROVIDER} 完成 (rc=$rc)"
    write_state "done-awaiting-review"
    exit 0
    ;;
  timeout)
    echo "$AGENT 超时 @ $(date -Iseconds) (timeout=${TIMEOUT_SECONDS}s, provider=$PROVIDER)" > "$SIG_DIR/${AGENT}_timeout"
    event "timeout" "${PROVIDER} 超时 ${TIMEOUT_SECONDS}s"
    write_state "timeout"
    exit 124
    ;;
  stale)
    # stale = work landed but signal interrupted; treat as done-awaiting-review per memory R55-R59 / R70 SOP
    : > "$SIG_DIR/${AGENT}_done"
    event "done" "${PROVIDER} stale-recovered (rc=$rc, work landed)"
    write_state "done-awaiting-review"
    exit 0
    ;;
  *)
    echo "$AGENT 失败 rc=$rc completion=$COMPLETION provider=$PROVIDER @ $(date -Iseconds)" > "$SIG_DIR/${AGENT}_failed"
    event "failed" "${PROVIDER} 失败 rc=$rc completion=$COMPLETION"
    write_state "failed"
    exit "${rc:-1}"
    ;;
esac
