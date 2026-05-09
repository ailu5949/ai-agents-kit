#!/usr/bin/env bash
# tests/smoke/_lib.sh — minimal POSIX shell test harness

set -uo pipefail

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

assert_eq() {
  local actual="$1" expected="$2" name="${3:-(unnamed)}"
  if [ "$actual" = "$expected" ]; then
    TESTS_PASSED=$((TESTS_PASSED+1))
    echo "  ✓ $name"
  else
    TESTS_FAILED=$((TESTS_FAILED+1))
    FAILED_NAMES+=("$name")
    echo "  ✗ $name"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="${3:-(unnamed)}"
  if echo "$haystack" | grep -qF "$needle"; then
    TESTS_PASSED=$((TESTS_PASSED+1))
    echo "  ✓ $name"
  else
    TESTS_FAILED=$((TESTS_FAILED+1))
    FAILED_NAMES+=("$name")
    echo "  ✗ $name"
    echo "    needle: '$needle' not found in:"
    echo "    $haystack" | head -5
  fi
}

assert_file_exists() {
  local path="$1" name="${2:-(unnamed)}"
  if [ -f "$path" ]; then
    TESTS_PASSED=$((TESTS_PASSED+1))
    echo "  ✓ $name"
  else
    TESTS_FAILED=$((TESTS_FAILED+1))
    FAILED_NAMES+=("$name")
    echo "  ✗ $name (file not found: $path)"
  fi
}

setup_fixture() {
  local name="$1"
  local dest
  dest="$(mktemp -d)"
  cp -r "$(dirname "$0")/../fixtures/$name/." "$dest/"
  echo "$dest"
}

cleanup_fixture() {
  local dir="$1"
  [ -d "$dir" ] && rm -rf "$dir"
}

report() {
  echo
  echo "===================="
  echo "PASS: $TESTS_PASSED"
  echo "FAIL: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "Failed tests:"
    for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
    exit 1
  fi
}
