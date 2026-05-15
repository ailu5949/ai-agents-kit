#!/usr/bin/env bash
# templates/.aiagents/bin/providers/codex.sh
# Codex CLI adapter for ai-agents-kit.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

provider_build_cmd() {
  # Codex reads prompt from stdin when "-" is passed as positional.
  # v3.4.1: --model 支持 (codex CLI 用 GPT-5 / GPT-5-codex 等, 默认让 codex 自己选)
  # PROVIDER_MODEL 来源: dispatch --model flag > agents.<a>.model > providers.codex.model
  local model_arg=""
  [ -n "${PROVIDER_MODEL:-}" ] && model_arg="--model $PROVIDER_MODEL"
  echo "cd '$WORK_ABS' && '$PROVIDER_BIN' exec $PROVIDER_ARGS $model_arg -"
}

provider_evaluate_completion() {
  # Get baseline decision
  local rc="${RC:-1}"
  local base
  base="$(default_evaluate_completion)"

  # Codex-specific override: rc=0 but log shows sandbox/permission denied → failed
  # (memory bugs.md 2026-05-02: --full-auto sandbox rc=0 false-done)
  if [ "$base" = "failed" ] && [ "$rc" -eq 0 ]; then
    echo "failed"; return
  fi
  if [ "$rc" -eq 0 ] && log_contains_any 'windows sandbox' 'CreateProcessAsUserW failed' 'permission denied'; then
    echo "failed"; return
  fi

  # Codex-specific override: rc=1 + stream disconnect log → stale
  # (memory bugs.md 2026-05-07 R70)
  if [ "$rc" -eq 1 ] && log_contains_any 'reconnecting' 'stream disconnect' '502 bad gateway' 'unexpected status 502'; then
    if [ "$base" = "failed" ]; then
      # rc=1 + 502 + clean tree (no work done) → real failed (502 SOP)
      # rc=1 + 502 + tree changed → stale (R70 SOP)
      local sb sa
      sb="${GIT_STATUS_BEFORE_FILE:-/dev/null}"
      sa="${GIT_STATUS_AFTER_FILE:-/dev/null}"
      if diff -q "$sb" "$sa" >/dev/null 2>&1 && [ -z "${COMMIT_AFTER:-}" -o "${COMMIT_BEFORE:-}" = "${COMMIT_AFTER:-}" ]; then
        echo "failed"; return
      fi
      echo "stale"; return
    fi
  fi

  echo "$base"
}
