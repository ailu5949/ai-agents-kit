#!/usr/bin/env bash
# templates/.aiagents/bin/providers/_common.sh
# Shared helpers used by every provider adapter and by agent-runner.sh.

# send_prompt_via_stdin <cmd_string> <prompt_file>
# Pipes prompt content to provider command via stdin.
send_prompt_via_stdin() {
  local cmd="$1" prompt_file="$2"
  # shellcheck disable=SC2002
  cat "$prompt_file" | bash -c "$cmd"
}

# default_evaluate_completion
# Reads RC LOG_FILE COMMIT_BEFORE COMMIT_AFTER GIT_STATUS_BEFORE_FILE GIT_STATUS_AFTER_FILE
# Writes one of done|failed|timeout|stale to stdout.
default_evaluate_completion() {
  local rc="${RC:-1}"
  local log="${LOG_FILE:-/dev/null}"
  local before="${COMMIT_BEFORE:-}"
  local after="${COMMIT_AFTER:-}"
  local sb_file="${GIT_STATUS_BEFORE_FILE:-/dev/null}"
  local sa_file="${GIT_STATUS_AFTER_FILE:-/dev/null}"

  local commit_advanced=0
  [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ] && commit_advanced=1

  local working_tree_changed=0
  if ! diff -q "$sb_file" "$sa_file" >/dev/null 2>&1; then
    working_tree_changed=1
  fi

  if [ "$rc" -eq 124 ]; then
    echo "timeout"; return
  fi
  if [ "$rc" -eq 0 ] && [ "$commit_advanced" -eq 1 ]; then
    echo "done"; return
  fi
  if [ "$rc" -ne 0 ] && { [ "$commit_advanced" -eq 1 ] || [ "$working_tree_changed" -eq 1 ]; }; then
    echo "stale"; return
  fi
  echo "failed"
}

# log_contains_any <regex> [regex ...]
# Returns 0 if LOG_FILE contains any of the patterns (case-insensitive).
log_contains_any() {
  local log="${LOG_FILE:-/dev/null}"
  [ -f "$log" ] || return 1
  for pat in "$@"; do
    if grep -qiE "$pat" "$log"; then return 0; fi
  done
  return 1
}

# record_provider_event <agent> <provider> <phase> <status> <message>
# Appends a JSONL line to events.jsonl with provider + phase fields.
record_provider_event() {
  local events_path="${EVENTS_FILE:?EVENTS_FILE must be set}"
  local agent="$1" provider="$2" phase="$3" status="$4" message="$5"
  "$PYTHON_BIN" - "$events_path" "$agent" "$provider" "$phase" "$status" "$message" <<'PY'
import json, sys, datetime, os
path, agent, provider, phase, status, message = sys.argv[1:7]
os.makedirs(os.path.dirname(path), exist_ok=True)
record = {
  "time": datetime.datetime.now().astimezone().isoformat(),
  "agent": agent,
  "provider": provider,
  "phase": phase,
  "status": status,
  "message": message,
}
with open(path, "a", encoding="utf-8") as f:
  f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY
}
