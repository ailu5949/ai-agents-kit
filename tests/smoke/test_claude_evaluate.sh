#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
KIT="$(cd "$DIR/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python}"
export PYTHON_BIN
# shellcheck disable=SC1091
source "$KIT/templates/.aiagents/bin/providers/claude.sh"

LOG_FILE="$(mktemp)"
SB="$(mktemp)"
SA="$(mktemp)"
export LOG_FILE GIT_STATUS_BEFORE_FILE="$SB" GIT_STATUS_AFTER_FILE="$SA"

# NOTE: inline env vars must be inside $(...) to propagate to function call —
# `VAR=val cmd "$(fn)"` expands $() in PARENT scope before VAR=val sets cmd's env.

# Case 1: rc=0 + commit advanced → done
> "$LOG_FILE"; echo "" > "$SB"; echo "" > "$SA"
assert_eq "$(RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=bbb provider_evaluate_completion)" "done" "rc=0 + commit → done"

# Case 2: rc=0 + interactive prompt → failed
echo "Waiting for input: continue?" > "$LOG_FILE"
assert_eq "$(RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa provider_evaluate_completion)" "failed" "rc=0 + prompt → failed"

# Case 3: rc=124 + clean → timeout
> "$LOG_FILE"; echo "" > "$SB"; echo "" > "$SA"
assert_eq "$(RC=124 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa provider_evaluate_completion)" "timeout" "rc=124 + clean → timeout"

# Case 3b: rc=124 + work landed → stale
> "$LOG_FILE"; echo "" > "$SB"; echo " M file.py" > "$SA"
assert_eq "$(RC=124 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa provider_evaluate_completion)" "stale" "rc=124 + tree changed → stale"

# Case 4: rc=1 + rate limit → failed
echo "Error: 429 rate limit exceeded" > "$LOG_FILE"
echo "" > "$SB"; echo " M file.py" > "$SA"
assert_eq "$(RC=1 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa provider_evaluate_completion)" "failed" "rc=1 + 429 → failed"

# Case 5: rc=1 + tree changed (no rate limit) → stale
> "$LOG_FILE"
echo "" > "$SB"; echo " M file.py" > "$SA"
assert_eq "$(RC=1 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa provider_evaluate_completion)" "stale" "rc=1 + tree changed → stale"

rm -f "$LOG_FILE" "$SB" "$SA"
report
