#!/usr/bin/env bash
# templates/.aiagents/bin/providers/claude.sh
# Claude Code CLI adapter for ai-agents-kit.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

provider_build_cmd() {
  # Claude Code reads stdin when no prompt arg is given to -p.
  echo "cd '$WORK_ABS' && '$PROVIDER_BIN' -p $PROVIDER_ARGS"
}

provider_evaluate_completion() {
  local rc="${RC:-1}"
  local base
  base="$(default_evaluate_completion)"

  # Claude-specific: rc=0 + interactive prompt indicator → failed (waiting for permission)
  if [ "$rc" -eq 0 ] && log_contains_any 'interactive prompt' 'waiting for input' 'continue\?' 'press enter'; then
    echo "failed"; return
  fi

  # Claude-specific: rc=1 + API rate limit → failed (no point claiming stale)
  if [ "$rc" -eq 1 ] && log_contains_any 'rate.?limit' '\b429\b' '\b529\b' 'api.*overload'; then
    echo "failed"; return
  fi

  echo "$base"
}
