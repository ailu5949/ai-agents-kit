#!/usr/bin/env bash
# templates/.aiagents/bin/providers/_template.sh
#
# ADAPTER CONTRACT — every providers/<name>.sh MUST define these two functions.
# This file is documentation, not loaded at runtime. Copy as starting point for
# new providers (e.g. providers/gemini.sh).

# provider_build_cmd
#   Builds the provider invocation command.
#   Reads (env): PROVIDER_BIN PROVIDER_ARGS PROVIDER_SUBCMD WORK_ABS
#   Writes to stdout: a single shell command string. Prompt is sent via stdin
#   by the caller (see _common.sh send_prompt_via_stdin).
#
#   Example (Codex):
#     echo "$PROVIDER_BIN exec $PROVIDER_ARGS -"
#
#   Example (Claude Code):
#     echo "$PROVIDER_BIN -p $PROVIDER_ARGS"
provider_build_cmd() {
  echo "echo 'unimplemented adapter'"
}

# provider_evaluate_completion
#   Decides what state to write after the provider exits.
#   Reads (env): RC LOG_FILE WORK_ABS
#                COMMIT_BEFORE COMMIT_AFTER
#                GIT_STATUS_BEFORE_FILE GIT_STATUS_AFTER_FILE
#   Writes to stdout: exactly one of: done | failed | timeout | stale
#
#   Reasoning hierarchy (default in _common.sh — override per provider):
#     1. RC=124 (timeout cmd killed it)         → timeout
#     2. RC=0 + commit advanced                  → done
#     3. RC=0 + working tree clean + log error   → failed
#     4. RC=1 + commit/work-tree changed         → stale (likely stream disconnect)
#     5. else                                    → failed
provider_evaluate_completion() {
  echo "failed"
}
