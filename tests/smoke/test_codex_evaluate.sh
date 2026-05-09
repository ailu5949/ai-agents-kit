#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"

# Source adapter (relative to kit root)
KIT="$(cd "$DIR/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python}"
export PYTHON_BIN
# shellcheck disable=SC1091
source "$KIT/templates/.aiagents/bin/providers/codex.sh"

WORK="$(mktemp -d)"
LOG_FILE="$(mktemp)"
SB="$(mktemp)"
SA="$(mktemp)"
export LOG_FILE GIT_STATUS_BEFORE_FILE="$SB" GIT_STATUS_AFTER_FILE="$SA"

# Case 1: rc=0 + commit advanced → done
RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=bbb assert_eq "$(provider_evaluate_completion)" "done" "rc=0 + commit advanced → done"

# Case 2: rc=0 + sandbox in log → failed
echo "windows sandbox: runner error" > "$LOG_FILE"
RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "failed" "rc=0 + sandbox log → failed"
> "$LOG_FILE"

# Case 3: rc=124 → timeout
RC=124 assert_eq "$(provider_evaluate_completion)" "timeout" "rc=124 → timeout"

# Case 4: rc=1 + 502 + clean tree → failed
echo "ERROR: unexpected status 502 Bad Gateway" > "$LOG_FILE"
echo "" > "$SB"
echo "" > "$SA"
RC=1 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "failed" "rc=1 + 502 + clean → failed"

# Case 5: rc=1 + stream disconnect + tree changed → stale
echo "ERROR: stream disconnected before completion" > "$LOG_FILE"
echo "" > "$SB"
echo " M file.py" > "$SA"
RC=1 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "stale" "rc=1 + stream + tree changed → stale"

# Case 6: rc=0 + no commit + clean → failed
> "$LOG_FILE"
echo "" > "$SB"
echo "" > "$SA"
RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "failed" "rc=0 + no work → failed"

rm -rf "$WORK" "$LOG_FILE" "$SB" "$SA"
report
