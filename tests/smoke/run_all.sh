#!/usr/bin/env bash
# tests/smoke/run_all.sh — orchestrator: run all test_*.sh, exit 0 if all pass.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
TOTAL=0
for t in "$DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  TOTAL=$((TOTAL+1))
  echo "====================================="
  echo "Running $(basename "$t")"
  echo "====================================="
  if ! bash "$t"; then
    FAILED=$((FAILED+1))
    echo "  [FAIL] $(basename "$t")"
  fi
  echo
done

echo "====================================="
echo "Suite: $TOTAL test files, $FAILED failed"
echo "====================================="
[ "$FAILED" -eq 0 ]
