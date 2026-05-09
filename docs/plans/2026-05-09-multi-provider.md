# Multi-Provider CLI Switching — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-agent + per-dispatch CLI provider switching (Codex / Claude Code, Gemini stub), strict three-stage workflow (encoded → reviewed → verified → human-decision), and main / coding agent context isolation, on top of ai-agents-kit v2.

**Architecture:** Provider abstraction = adapter `.sh` per CLI exposing `provider_build_cmd` + `provider_evaluate_completion`. Agent-runner becomes provider-agnostic (resolves provider → sources adapter → sends prompt via stdin). State enum extends with `claude-verifying` / `ready-for-human` for the new gate. Coding agent isolation = subdirectory CLAUDE.md (Claude-Code-only path) + cross-provider stdin preamble (universal) + main settings.json `Edit/Write` deny on business dirs.

**Tech Stack:** Bash 4+, PowerShell 7+, Python 3 (jq/python config helpers), JSON (config), Markdown (slash commands + CLAUDE.md), POSIX shell test harness.

**Spec reference:** [docs/designs/2026-05-09-multi-provider-design.md](../designs/2026-05-09-multi-provider-design.md)

---

## File Structure

### New files (17)

| Path | Purpose |
|---|---|
| `templates/.aiagents/bin/providers/_common.sh` | Shared helpers: `send_prompt_via_stdin` / `default_evaluate_completion` / `record_provider_event` |
| `templates/.aiagents/bin/providers/_template.sh` | Documented adapter contract example for new providers |
| `templates/.aiagents/bin/providers/codex.sh` | Codex adapter |
| `templates/.aiagents/bin/providers/claude.sh` | Claude Code adapter |
| `templates/.aiagents/prompts/dispatch-preamble.md` | Cross-provider shared dispatch discipline (~300 字) |
| `templates/backend-CLAUDE.md` | Backend coding-agent专用 CLAUDE.md (deployed to `${BACKEND_DIR}/CLAUDE.md`) |
| `templates/frontend-CLAUDE.md` | Frontend coding-agent专用 CLAUDE.md |
| `templates/.claude/commands/release-without-verify.md` | Bypass-gate slash command |
| `tests/smoke/_lib.sh` | Bash test helpers: `assert_eq` / `assert_contains` / `setup_fixture` / `cleanup` |
| `tests/smoke/test_resolve_provider.sh` | Unit test: provider resolution (cli flag → agent default → global default) |
| `tests/smoke/test_codex_evaluate.sh` | Unit test: Codex `evaluate_completion` cases |
| `tests/smoke/test_claude_evaluate.sh` | Unit test: Claude `evaluate_completion` cases |
| `tests/smoke/test_migrate_v2_to_v3.sh` | Integration test: schema migration on fixture v2 project |
| `tests/smoke/test_dispatch_e2e.sh` | Integration test: dry-run dispatch w/ each provider (uses fake provider stub) |
| `tests/smoke/run_all.sh` | Orchestrator: run all `test_*.sh`, exit 0 if all pass |
| `tests/fixtures/v2-project/` | Fake v2 project layout (config.json + .aiagents/ + docs/ai-agents/) for migration tests |
| `docs/plans/2026-05-09-multi-provider.md` | This file |

### Modified files (13)

| Path | Change |
|---|---|
| `templates/.aiagents/bin/agent-runner.sh` | Provider resolution + adapter sourcing + stdin prompt + new evaluate_completion |
| `templates/.aiagents/bin/agentctl.sh` | `dispatch [--provider X] [--timeout N]`; `status` + Provider column; new `release-without-verify` subcmd |
| `templates/.aiagents/bin/agentctl.ps1` | PowerShell equivalent |
| `templates/.aiagents/bin/watch-agent.sh` | Pass-through provider env to runner |
| `templates/.claude/commands/dispatch-backend.md` | Parse `$ARGUMENTS` → forward to agentctl |
| `templates/.claude/commands/dispatch-frontend.md` | Same |
| `templates/.claude/commands/bugfix-backend.md` | Same |
| `templates/.claude/commands/bugfix-frontend.md` | Same |
| `templates/.claude/settings.json` | `permissions.deny` Edit/Write `${BACKEND_DIR}/**` `${FRONTEND_DIR}/**` |
| `templates/CLAUDE.md` | New `## ⛔ provider 同源审查纪律` section + `## ⛔ Pre-Human Decision Gate` section |
| `install.sh` | v2→v3 migration logic + deploy subdir CLAUDE.md + run smoke test |
| `install.ps1` | Same (Windows path) |

---

## Phase 0 — Foundation: git + tests harness + adapter contract

### Task 0.0: Initialize git repo for the kit + commit baseline

**Files:** none (git infrastructure)

- [ ] **Step 1: Init git in kit root**

```bash
cd C:/Users/mi/ai-agents-kit
git init
```

- [ ] **Step 2: Create .gitignore**

Write `C:/Users/mi/ai-agents-kit/.gitignore`:

```
.tmp_*
*.bak
node_modules/
__pycache__/
.pytest_cache/
.DS_Store
tests/fixtures/*/work/
```

- [ ] **Step 3: Commit baseline**

```bash
git add -A
git commit -m "chore: baseline pre multi-provider work"
```

Expected: Commit succeeds with all current kit files staged.

---

### Task 0.1: Create test harness lib

**Files:**
- Create: `tests/smoke/_lib.sh`

- [ ] **Step 1: Write _lib.sh with assertion + fixture helpers**

```bash
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
```

- [ ] **Step 2: Smoke test the harness with a trivial check**

```bash
bash -c 'source tests/smoke/_lib.sh && assert_eq "1" "1" "trivial" && report'
```

Expected: `PASS: 1 / FAIL: 0`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/_lib.sh
git commit -m "test: add minimal bash test harness"
```

---

### Task 0.2: Adapter contract template

**Files:**
- Create: `templates/.aiagents/bin/providers/_template.sh`

- [ ] **Step 1: Write _template.sh with documented contract**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add templates/.aiagents/bin/providers/_template.sh
git commit -m "feat: provider adapter contract template"
```

---

### Task 0.3: Shared helpers `_common.sh`

**Files:**
- Create: `templates/.aiagents/bin/providers/_common.sh`

- [ ] **Step 1: Write _common.sh**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add templates/.aiagents/bin/providers/_common.sh
git commit -m "feat: shared provider helpers (stdin send + default evaluate + event)"
```

---

## Phase 1 — Codex adapter (refactor existing inline logic)

### Task 1.1: Write Codex adapter

**Files:**
- Create: `templates/.aiagents/bin/providers/codex.sh`

- [ ] **Step 1: Write codex.sh**

```bash
#!/usr/bin/env bash
# templates/.aiagents/bin/providers/codex.sh
# Codex CLI adapter for ai-agents-kit.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

provider_build_cmd() {
  # Codex reads prompt from stdin when "-" is passed as positional.
  echo "cd '$WORK_ABS' && '$PROVIDER_BIN' exec $PROVIDER_ARGS -"
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
```

- [ ] **Step 2: Write unit test for evaluate cases**

Create `tests/smoke/test_codex_evaluate.sh`:

```bash
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
```

- [ ] **Step 3: Run test, expect all 6 cases pass**

```bash
chmod +x tests/smoke/test_codex_evaluate.sh
bash tests/smoke/test_codex_evaluate.sh
```

Expected: `PASS: 6 / FAIL: 0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add templates/.aiagents/bin/providers/codex.sh tests/smoke/test_codex_evaluate.sh
git commit -m "feat: codex adapter + 6-case evaluate_completion test"
```

---

## Phase 2 — Claude Code adapter

### Task 2.1: Write Claude Code adapter

**Files:**
- Create: `templates/.aiagents/bin/providers/claude.sh`

- [ ] **Step 1: Write claude.sh**

```bash
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
```

- [ ] **Step 2: Write unit test**

Create `tests/smoke/test_claude_evaluate.sh`:

```bash
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

# Case 1: rc=0 + commit advanced → done
> "$LOG_FILE"; echo "" > "$SB"; echo "" > "$SA"
RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=bbb assert_eq "$(provider_evaluate_completion)" "done" "rc=0 + commit → done"

# Case 2: rc=0 + interactive prompt → failed
echo "Waiting for input: continue?" > "$LOG_FILE"
RC=0 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "failed" "rc=0 + prompt → failed"

# Case 3: rc=124 → timeout
> "$LOG_FILE"
RC=124 assert_eq "$(provider_evaluate_completion)" "timeout" "rc=124 → timeout"

# Case 4: rc=1 + rate limit → failed
echo "Error: 429 rate limit exceeded" > "$LOG_FILE"
echo "" > "$SB"; echo " M file.py" > "$SA"
RC=1 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "failed" "rc=1 + 429 → failed"

# Case 5: rc=1 + tree changed (no rate limit) → stale
> "$LOG_FILE"
echo "" > "$SB"; echo " M file.py" > "$SA"
RC=1 COMMIT_BEFORE=aaa COMMIT_AFTER=aaa assert_eq "$(provider_evaluate_completion)" "stale" "rc=1 + tree changed → stale"

rm -f "$LOG_FILE" "$SB" "$SA"
report
```

- [ ] **Step 3: Run test, expect 5 cases pass**

```bash
chmod +x tests/smoke/test_claude_evaluate.sh
bash tests/smoke/test_claude_evaluate.sh
```

Expected: `PASS: 5 / FAIL: 0`.

- [ ] **Step 4: Commit**

```bash
git add templates/.aiagents/bin/providers/claude.sh tests/smoke/test_claude_evaluate.sh
git commit -m "feat: claude code adapter + 5-case evaluate_completion test"
```

---

## Phase 3 — Provider resolution + dispatch override

### Task 3.1: Refactor `agent-runner.sh` to use adapter

**Files:**
- Modify: `templates/.aiagents/bin/agent-runner.sh` (existing 269-line file)

- [ ] **Step 1: Read current agent-runner.sh fully**

```bash
cat templates/.aiagents/bin/agent-runner.sh
```

Expected: confirm familiarity with current Codex inline logic at lines 70-76 (config_value resolution) and lines 240-249 (codex exec invocation).

- [ ] **Step 2: Add provider resolution function before the Codex block (after `config_value` definition, around line 68)**

Insert after the existing `config_value()` function:

```bash
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
```

- [ ] **Step 3: Replace lines 70-76 (CODEX_BIN/CODEX_ARGS/TIMEOUT_SECONDS resolution) with provider-aware resolution**

Replace:

```bash
WORK_DIR="$(config_value "${AGENT}.dir" "$( [ "$AGENT" = backend ] && echo BACKEND_DIR || echo FRONTEND_DIR )")"
CODEX_BIN="$(config_value codex.bin CODEX_BIN)"
[ -z "$CODEX_BIN" ] && CODEX_BIN="codex"
CODEX_ARGS="$(config_value codex.args CODEX_ARGS)"
[ -z "$CODEX_ARGS" ] && CODEX_ARGS="--full-auto"
TIMEOUT_SECONDS="$(config_value codex.timeout_seconds CODEX_TIMEOUT)"
[ -z "$TIMEOUT_SECONDS" ] && TIMEOUT_SECONDS="1800"
```

With:

```bash
WORK_DIR="$(config_value "agents.${AGENT}.dir" "$( [ "$AGENT" = backend ] && echo BACKEND_DIR || echo FRONTEND_DIR )")"
PROVIDER="$(resolve_provider "$AGENT")"
PROVIDER_BIN="$(config_value "providers.${PROVIDER}.bin" "")"
[ -z "$PROVIDER_BIN" ] && PROVIDER_BIN="$PROVIDER"
PROVIDER_ARGS="$(config_value "providers.${PROVIDER}.args" "")"
PROVIDER_SUBCMD="$(config_value "providers.${PROVIDER}.subcommand" "")"
TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE:-$(config_value "providers.${PROVIDER}.timeout" "")}"
[ -z "$TIMEOUT_SECONDS" ] && TIMEOUT_SECONDS="1800"

# v2 fallback: if providers.* block missing, fall back to legacy codex.* for one transition release
if [ -z "$PROVIDER_BIN" ] || [ "$PROVIDER" = "codex" -a -z "$PROVIDER_ARGS" ]; then
  legacy_bin="$(config_value codex.bin CODEX_BIN)"
  legacy_args="$(config_value codex.args CODEX_ARGS)"
  [ -n "$legacy_bin" ] && [ -z "$PROVIDER_BIN" ] && PROVIDER_BIN="$legacy_bin"
  [ -n "$legacy_args" ] && [ -z "$PROVIDER_ARGS" ] && PROVIDER_ARGS="$legacy_args"
fi
[ -z "$PROVIDER_ARGS" ] && [ "$PROVIDER" = "codex" ] && PROVIDER_ARGS="--dangerously-bypass-approvals-and-sandbox"
[ -z "$PROVIDER_ARGS" ] && [ "$PROVIDER" = "claude" ] && PROVIDER_ARGS="--dangerously-skip-permissions"

export PROVIDER_BIN PROVIDER_ARGS PROVIDER_SUBCMD WORK_ABS LOG_FILE EVENTS_FILE PYTHON_BIN
```

- [ ] **Step 4: Replace the Codex execution block (lines ~239-249)**

Find the block:

```bash
set +e
(
  cd "$WORK_ABS" || exit 4
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    timeout "$TIMEOUT_SECONDS" "$CODEX_BIN" exec $CODEX_ARGS "$PROMPT" 2>&1
  else
    # shellcheck disable=SC2086
    "$CODEX_BIN" exec $CODEX_ARGS "$PROMPT" 2>&1
  fi
) | tee -a "$LOG" | bash "$BIN_DIR/filter-output.sh"
rc=${PIPESTATUS[0]}
set -e
```

Replace with:

```bash
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

CMD_TEMPLATE="$(provider_build_cmd)"

set +e
if command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC2002,SC2086
  cat "$PROMPT_FILE" | timeout "$TIMEOUT_SECONDS" bash -c "$CMD_TEMPLATE" 2>&1 | tee -a "$LOG" | bash "$BIN_DIR/filter-output.sh"
else
  # shellcheck disable=SC2002,SC2086
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
```

- [ ] **Step 5: Replace the rc-handling block (lines ~253-268) with completion-driven**

Find:

```bash
if [ "$rc" -eq 124 ]; then
  echo "$AGENT 超时 @ $(date -Iseconds) (timeout=${TIMEOUT_SECONDS}s)" > "$SIG_DIR/${AGENT}_timeout"
  event "timeout" "Codex 超时 ${TIMEOUT_SECONDS}s"
  write_state "timeout"
  exit 124
elif [ "$rc" -eq 0 ]; then
  : > "$SIG_DIR/${AGENT}_done"
  event "done" "Codex 完成"
  write_state "done-awaiting-review"
  exit 0
else
  echo "$AGENT 失败 rc=$rc @ $(date -Iseconds)" > "$SIG_DIR/${AGENT}_failed"
  event "failed" "Codex 失败 rc=$rc"
  write_state "failed"
  exit "$rc"
fi
```

Replace with:

```bash
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
```

- [ ] **Step 6: Update `event()` to include provider field**

Find the `event()` function definition. Modify to take provider into account by exporting `PROVIDER` before each call (PROVIDER is already in scope from Step 3 above). Update the Python heredoc to write `provider` field:

In the `event()` function, replace the heredoc body with:

```python
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
```

And update the function call line from `"$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" "$status" "$message" <<'PY'` to:

```bash
"$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" "$status" "$message" "${PROVIDER:-unknown}" <<'PY'
```

- [ ] **Step 7: Smoke run (existing v2 project)**

Test on choseStock fixture (it has v2 config.json with `codex.*` block, no `providers.*`). The fallback path should still work:

```bash
cd /d/dev/ai/workspace/choseStock
# Make sure there's a queued backend signal first to test
ls .aiagents/signals/ 2>/dev/null
```

If no queued signal, just exercise the resolve_provider path:

```bash
bash -c '
  PYTHON_BIN=python
  ROOT=/d/dev/ai/workspace/choseStock
  CONFIG_JSON=$ROOT/.aiagents/config.json
  CONFIG_CONF=$ROOT/.claude/agents.conf
  source <(awk "/^config_value\(\)/,/^}/" $ROOT/../../../mi/ai-agents-kit/templates/.aiagents/bin/agent-runner.sh)
  source <(awk "/^resolve_provider\(\)/,/^}/" $ROOT/../../../mi/ai-agents-kit/templates/.aiagents/bin/agent-runner.sh)
  resolve_provider backend
'
```

Expected: `codex` (because v2 config has no `agents.backend.provider`, fall through to default which falls through to hardcoded `codex`).

- [ ] **Step 8: Commit**

```bash
git add templates/.aiagents/bin/agent-runner.sh
git commit -m "refactor(runner): provider abstraction + adapter sourcing + stdin prompt"
```

---

### Task 3.2: Add `--provider` `--timeout` flags to `agentctl.sh`

**Files:**
- Modify: `templates/.aiagents/bin/agentctl.sh`

- [ ] **Step 1: Read current agentctl.sh dispatch subcmd**

```bash
grep -n "^dispatch\|dispatch_" templates/.aiagents/bin/agentctl.sh | head -20
```

- [ ] **Step 2: Update the `dispatch` subcommand parser**

Locate the `dispatch` case branch. Replace its argument parsing with:

```bash
dispatch)
  shift
  AGENT=""
  PROVIDER_OVERRIDE=""
  TIMEOUT_OVERRIDE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) PROVIDER_OVERRIDE="$2"; shift 2 ;;
      --timeout)  TIMEOUT_OVERRIDE="$2";  shift 2 ;;
      backend|frontend) AGENT="$1"; shift ;;
      *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
  done
  [ -z "$AGENT" ] && { echo "用法: agentctl.sh dispatch [--provider X] [--timeout N] backend|frontend" >&2; exit 2; }

  # Validate provider exists in config (if override given)
  if [ -n "$PROVIDER_OVERRIDE" ]; then
    bin="$("$PYTHON_BIN" - "$CONFIG_JSON" "providers.${PROVIDER_OVERRIDE}.bin" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    cur = d
    for p in sys.argv[2].split('.'): cur = cur[p]
    print(cur)
except Exception: pass
PY
)"
    if [ -z "$bin" ]; then
      echo "未配置 provider: $PROVIDER_OVERRIDE (config.json 中 providers.* 仅含: $(jq -r '.providers | keys | join(",")' "$CONFIG_JSON" 2>/dev/null || echo unknown))" >&2
      exit 2
    fi
  fi

  # Write signal payload (file body = json metadata for runner to pick up)
  mkdir -p "$SIG_DIR"
  cat > "$SIG_DIR/task_ready_${AGENT}" <<EOF
{"provider_override":"${PROVIDER_OVERRIDE}","timeout_override":"${TIMEOUT_OVERRIDE}","queued_at":"$(date -Iseconds)"}
EOF
  echo "queued: agent=$AGENT provider=${PROVIDER_OVERRIDE:-default} timeout=${TIMEOUT_OVERRIDE:-default}"
  ;;
```

- [ ] **Step 3: Update `bugfix` subcommand similarly**

Same pattern: add `--provider` `--timeout` flag parsing, write to `bugfix_${AGENT}` signal file with same JSON body.

- [ ] **Step 4: Add `release-without-verify` subcommand**

Add new case branch:

```bash
release-without-verify)
  shift
  AGENT="$1"; shift
  REASON="$*"
  [ -z "$AGENT" ] || [ -z "$REASON" ] && { echo "用法: agentctl.sh release-without-verify <backend|frontend> <reason>" >&2; exit 2; }

  # Force state to ready-for-human, log bypass event
  "$PYTHON_BIN" - "$STATE_DIR/current.json" "$AGENT" <<'PY'
import json, sys, datetime
path, agent = sys.argv[1:3]
data = json.load(open(path, encoding='utf-8'))
data.setdefault("agents", data).setdefault(agent, {})["state"] = "ready-for-human"
data["updated_at"] = datetime.datetime.now().astimezone().isoformat()
open(path, "w", encoding='utf-8').write(json.dumps(data, ensure_ascii=False, indent=2)+"\n")
PY

  # Append bypass event
  "$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" "$REASON" <<'PY'
import json, sys, datetime, os
path, agent, reason = sys.argv[1:4]
record = {
  "time": datetime.datetime.now().astimezone().isoformat(),
  "agent": agent,
  "phase": "verify-bypassed",
  "status": "ready-for-human",
  "reason": reason,
  "by": "lane",
}
open(path, "a", encoding='utf-8').write(json.dumps(record, ensure_ascii=False)+"\n")
PY

  # Append to memory bugs.md (if exists)
  MEMORY_BUGS="$ROOT/.aiagents/memory/global/bugs.md"
  if [ -f "$MEMORY_BUGS" ]; then
    {
      echo
      echo "## $(date '+%Y-%m-%d %H:%M') · verify-bypass: ${AGENT}"
      echo
      echo "**触发**: \`/release-without-verify $AGENT \"$REASON\"\` 显式破例"
      echo
      echo "**reason**: $REASON"
      echo
      echo "**待补**: 后续阶段 review 时核对该轮是否有遗漏 bug"
      echo
    } >> "$MEMORY_BUGS"
  fi

  echo "released without verify: agent=$AGENT reason=$REASON"
  ;;
```

- [ ] **Step 5: Update `status` subcommand to print Provider column**

In the `status` case branch, find the agent-row Python heredoc and add `provider` field rendering. Add to each row output something like `agent=...  provider=...  state=...`.

- [ ] **Step 6: Smoke test**

```bash
# In choseStock (v2 fixture)
cd /d/dev/ai/workspace/choseStock
bash .aiagents/bin/agentctl.sh dispatch --provider unknown_x backend 2>&1 | head -3
```

Expected: error message like `未配置 provider: unknown_x ...`, exit code 2.

```bash
bash .aiagents/bin/agentctl.sh dispatch --provider codex --timeout 600 backend
ls .aiagents/signals/task_ready_backend
cat .aiagents/signals/task_ready_backend
```

Expected: signal file contains `{"provider_override":"codex","timeout_override":"600",...}`. Then immediately remove it to avoid triggering watcher:

```bash
rm .aiagents/signals/task_ready_backend
```

- [ ] **Step 7: Commit**

```bash
git add templates/.aiagents/bin/agentctl.sh
git commit -m "feat(agentctl): --provider --timeout flags + release-without-verify subcmd"
```

---

### Task 3.3: PowerShell equivalent in `agentctl.ps1`

**Files:**
- Modify: `templates/.aiagents/bin/agentctl.ps1`

- [ ] **Step 1: Read current ps1**

```bash
cat templates/.aiagents/bin/agentctl.ps1 | head -100
```

- [ ] **Step 2: Mirror Bash changes in PowerShell**

Add equivalent `-Provider` `-Timeout` parameters to dispatch / bugfix functions. Add `Release-WithoutVerify` function. Same JSON body to signal file.

(Code structure will mirror Task 3.2 — adapt syntax to PowerShell: `param([string]$Provider, [int]$Timeout)`, `Set-Content`, `ConvertTo-Json`, etc.)

- [ ] **Step 3: Smoke test on Windows**

```powershell
cd D:\dev\ai\workspace\choseStock
pwsh .aiagents\bin\agentctl.ps1 dispatch -Provider codex -Timeout 600 -Agent backend
Get-Content .aiagents\signals\task_ready_backend
Remove-Item .aiagents\signals\task_ready_backend
```

Expected: same JSON body shape as Bash variant.

- [ ] **Step 4: Commit**

```bash
git add templates/.aiagents/bin/agentctl.ps1
git commit -m "feat(agentctl-ps): mirror --provider --timeout + release-without-verify"
```

---

### Task 3.4: Update `watch-agent.sh` to read signal payload

**Files:**
- Modify: `templates/.aiagents/bin/watch-agent.sh`

- [ ] **Step 1: Read current signal-detection block**

```bash
grep -n "task_ready_\|bugfix_" templates/.aiagents/bin/watch-agent.sh
```

- [ ] **Step 2: Parse JSON body from signal file before invoking runner**

Before the `bash agent-runner.sh ...` call, add:

```bash
SIGNAL_BODY="$(cat "$SIGNAL_FILE" 2>/dev/null)"
if [ -n "$SIGNAL_BODY" ] && echo "$SIGNAL_BODY" | grep -q "provider_override"; then
  PROVIDER_OVERRIDE="$("$PYTHON_BIN" -c "import json,sys; print(json.loads(sys.argv[1]).get('provider_override',''))" "$SIGNAL_BODY")"
  TIMEOUT_OVERRIDE="$("$PYTHON_BIN" -c "import json,sys; print(json.loads(sys.argv[1]).get('timeout_override',''))" "$SIGNAL_BODY")"
  export PROVIDER_OVERRIDE TIMEOUT_OVERRIDE
fi
```

- [ ] **Step 3: Smoke test**

Manually create a signal with override, watch the runner pick it up:

```bash
cd /d/dev/ai/workspace/choseStock
echo '{"provider_override":"codex","timeout_override":"60","queued_at":"now"}' > .aiagents/signals/task_ready_backend
# (do NOT actually start watcher, just verify the parsing logic)
bash -c '
  SIGNAL_FILE=.aiagents/signals/task_ready_backend
  PYTHON_BIN=python
  SIGNAL_BODY="$(cat "$SIGNAL_FILE" 2>/dev/null)"
  PROVIDER_OVERRIDE="$("$PYTHON_BIN" -c "import json,sys; print(json.loads(sys.argv[1]).get(\"provider_override\",\"\"))" "$SIGNAL_BODY")"
  echo "got provider: $PROVIDER_OVERRIDE"
'
rm .aiagents/signals/task_ready_backend
```

Expected: `got provider: codex`.

- [ ] **Step 4: Commit**

```bash
git add templates/.aiagents/bin/watch-agent.sh
git commit -m "feat(watch): parse provider_override from signal payload"
```

---

### Task 3.5: Update 4 dispatch/bugfix slash commands

**Files:**
- Modify: `templates/.claude/commands/dispatch-backend.md`
- Modify: `templates/.claude/commands/dispatch-frontend.md`
- Modify: `templates/.claude/commands/bugfix-backend.md`
- Modify: `templates/.claude/commands/bugfix-frontend.md`

- [ ] **Step 1: Read existing dispatch-backend.md**

```bash
cat templates/.claude/commands/dispatch-backend.md
```

- [ ] **Step 2: Update body to forward `$ARGUMENTS`**

Replace the `bash` invocation line. Old form:

```bash
bash "$(git rev-parse --show-toplevel)/.aiagents/bin/agentctl.sh" dispatch backend
```

New form:

```bash
bash "$(git rev-parse --show-toplevel)/.aiagents/bin/agentctl.sh" dispatch $ARGUMENTS backend
```

(`$ARGUMENTS` is Claude Code's variable containing slash-command flags like `--provider claude`.)

Also add a header note explaining usage:

```markdown
> Usage:
>   /dispatch-backend                          (use agent default provider)
>   /dispatch-backend --provider claude        (override provider for this dispatch)
>   /dispatch-backend --provider claude --timeout 3600
```

- [ ] **Step 3: Apply same change to the other 3 commands**

Same pattern, with `frontend` / `bugfix backend` / `bugfix frontend` substituted.

- [ ] **Step 4: Commit**

```bash
git add templates/.claude/commands/dispatch-backend.md \
        templates/.claude/commands/dispatch-frontend.md \
        templates/.claude/commands/bugfix-backend.md \
        templates/.claude/commands/bugfix-frontend.md
git commit -m "feat(slash): forward \$ARGUMENTS to agentctl for --provider/--timeout"
```

---

## Phase 4 — State schema + Verify Gate

### Task 4.1: Extend state enum + write Pre-Human Decision Gate to CLAUDE.md template

**Files:**
- Modify: `templates/CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md sections**

```bash
grep -n "^## " templates/CLAUDE.md
```

- [ ] **Step 2: Insert new section after `## ⛔ 审查触发 — 硬约束(别绕过)`**

Find the line `## ⛔ 审查触发 — 硬约束(别绕过)` and the section ending after the closing `> <!-- ai-agents-kit:end v2 -->` is far below. Find the end of that 审查触发 section (typically the next `##` heading) and insert before it:

```markdown
## ⛔ provider 同源审查纪律 (multi-provider 后)

历史教训: Codex 与主 Claude 异构,审查无"同根偏向"风险。
multi-provider 后编码 agent 可选 Claude Code(同模型不同会话),你和它对你而言仍是"外部 agent",规则不变:

- ❌ 严禁因"反正都是 Claude"放松审查 — Karpathy 6 项与 Codex 派单时同等严格
- ❌ 严禁用"它应该是这样想的"代替"git diff 实际证据"
- ❌ 严禁"顺手帮一下"自己改代码 — 编码 agent 失败仍走 04 修复 → 重派,不论 provider
- ✅ 你只看 state.json + events.jsonl + git diff + log + commit message — 不能假设编码 agent 的 thinking
- ✅ 审查报告必须写明 `**Provider**: codex | claude` 字段(由你写,不依赖 events.jsonl)

## ⛔ Pre-Human Decision Gate (人工决策前必经关卡)

**三段式工作流**:
```
编码 agent 完成 → state=done-awaiting-review
       ↓ 主 Claude 走 Karpathy 6 项审查
state=claude-verifying ← 主 Claude **真打**跑测试 + curl smoke + E2E
       ↓ 全过
state=ready-for-human ← Lane 拍板:收下 / 打回 / 推迟
```

**done-awaiting-review 不再直接交人工**。审查通过后必须:

1. 写 `state=claude-verifying`
2. 跑下表所有项(命令从 `.aiagents/config.json` `agents.<a>.test_cmd / lint_cmd / smoke_endpoints` 读)
3. 任一失败 → 04-Bug修复 → 派编码 agent → 回起点
4. 全过 → 写 `state=ready-for-human` + 通知 Lane

**验证清单**:

| 类别 | 命令 | 通过判据 |
|---|---|---|
| 后端测试 | `cd $BACKEND_DIR && $TEST_CMD` | exit 0 + 测试数 ≥ spec 验收 + 无 regression |
| 后端 lint | `cd $BACKEND_DIR && $LINT_CMD` | exit 0 |
| 后端 import | `$IMPORT_CHECK` | "OK" + 无 ImportError |
| 接口 smoke | `curl -fsS $ENDPOINT` × N | 全 200 + 含 spec 要求字段 |
| 真 E2E | `$E2E_CMD` | exit 0 + 行数验证 + 数据形状 |
| 前端构建 | `cd $FRONTEND_DIR && $BUILD_CMD` | exit 0 + dist 产物存在 |
| 前端 lint | `cd $FRONTEND_DIR && $LINT_CMD` | exit 0 |
| 前端 file:// smoke | `agents.frontend.smoke_grep` 各项 | 全部命中预期值 |

**任一 stdout/stderr 含** `error|fail|exception|traceback|sandbox|forbidden|denied|connection refused`(case-insensitive)→ 主 Claude 必须解释,不能略过。

**审查报告必含 § 真打验证段**(模板):

```markdown
### § 真打验证 (Pre-Human Decision Gate)

| 验证项 | 命令 | exit | 输出尾 5 行 | 通过 |
|---|---|---|---|---|
| BE 测试 | `pytest -q` | 0 | `... 86 passed in 12.3s` | ✅ |
| BE lint | `ruff check .` | 0 | `All checks passed!` | ✅ |
| ... | ... | ... | ... | ... |

**全部 ✅ → state 推进 ready-for-human**
```

**报告未含此段 = 报告无效**(主 Claude 不能"忘了跑")。

**应急 bypass**: Lane 显式 `/release-without-verify <agent> "<reason>"` 可绕过 — 但每次破例自动写入 `bugs.md` 留痕。

**主 Claude 运维边界**: 跑测试 / 跑接口 / kill 进程 / 起 server **可做**(运维操作);Edit / Write 业务代码 **严禁**(由 settings.json deny 强制)。
```

- [ ] **Step 3: Commit**

```bash
git add templates/CLAUDE.md
git commit -m "docs(CLAUDE): add provider 同源审查纪律 + Pre-Human Decision Gate"
```

---

### Task 4.2: Update `agent-runner.sh` to write provider to state

**Files:**
- Modify: `templates/.aiagents/bin/agent-runner.sh`

- [ ] **Step 1: Locate `write_state` function in agent-runner.sh**

```bash
grep -n "write_state\(\)" templates/.aiagents/bin/agent-runner.sh
```

- [ ] **Step 2: Pass PROVIDER into the Python heredoc and write into snapshot**

Replace the `write_state()` body's Python heredoc to add provider field. After the snapshot construction:

```python
snapshot = {
    "updated_at": now.isoformat(),
    ...
    "backend":  {"dir": ..., "stack": ..., "state": state("backend")},
    "frontend": {"dir": ..., "stack": ..., "state": state("frontend")},
    ...
}
```

Add provider to the per-agent dict by reading from config:

```python
def agent_provider(name):
    try:
        return config["agents"][name].get("provider") or config.get("default_provider", "codex")
    except Exception:
        return config.get("default_provider", "codex")

snapshot["backend"]["provider"]  = agent_provider("backend")
snapshot["frontend"]["provider"] = agent_provider("frontend")
```

If the runner is currently running an override, that's known via env `PROVIDER_OVERRIDE` — pass it through and use it in place when matching agent:

```bash
write_state() {
  local running_state="$1"
  "$PYTHON_BIN" - "$ROOT" "$AGENT" "$running_state" "$RUNTIME_DIR" "$STATE_DIR" "$CONFIG_JSON" "$CONFIG_CONF" "${PROVIDER:-}" "${PROVIDER_OVERRIDE:-}" <<'PY'
```

And in Python:

```python
runtime_provider = sys.argv[7]   # the resolved one for this run
override = sys.argv[8]           # whatever the dispatcher passed
# When agent matches the running one, use runtime_provider; else use config default.
```

- [ ] **Step 3: Smoke test on choseStock**

```bash
cd /d/dev/ai/workspace/choseStock
PROVIDER=claude PROVIDER_OVERRIDE=claude bash .aiagents/bin/agent-runner.sh backend task 2>&1 | head -10
# (Will fail because spec missing or claude not installed, but should still write state.json)
cat .aiagents/state/current.json | python -c "import json,sys; d=json.load(sys.stdin); print('backend provider:', d['backend'].get('provider'))"
```

Expected: `backend provider: claude` (or codex if override didn't apply — investigate).

- [ ] **Step 4: Revert state to clean state**

```bash
# manually reset state.json provider to codex
```

- [ ] **Step 5: Commit**

```bash
git add templates/.aiagents/bin/agent-runner.sh
git commit -m "feat(state): expose provider in state.json per-agent"
```

---

### Task 4.3: New `release-without-verify` slash command

**Files:**
- Create: `templates/.claude/commands/release-without-verify.md`

- [ ] **Step 1: Write the slash command**

```markdown
---
description: 应急 — 跳过主 Claude 真打验证,直接推进 ready-for-human (Lane 显式破例)
---

> Usage: /release-without-verify <backend|frontend> "<reason>"
> 例: /release-without-verify backend "生产 hot-fix,LLM 限流影响 verify"
>
> 后果:
> - state 直接 done-awaiting-review → ready-for-human
> - events.jsonl 写入 phase=verify-bypassed 记录
> - .aiagents/memory/global/bugs.md 自动追加破例条目(供未来 review 核查)
>
> 默认 OFF,Lane 主动敲。每次破例进 memory。

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
bash "$ROOT/.aiagents/bin/agentctl.sh" release-without-verify $ARGUMENTS
```
```

- [ ] **Step 2: Commit**

```bash
git add templates/.claude/commands/release-without-verify.md
git commit -m "feat(slash): release-without-verify bypass gate"
```

---

### Task 4.4: Provider 切换接续 (Handover 机制)

**Files:**
- Modify: `templates/.aiagents/bin/agent-runner.sh`
- Modify: `templates/.aiagents/bin/agentctl.sh`
- Modify: `templates/CLAUDE.md`
- Create: `templates/.claude/commands/retry-other-provider.md`

**Context (spec § 7.5)**: 编码 agent 是无状态的(每次派单 fresh process)。当 claude 跑了 60% 失败切到 codex,如果不处理 codex 看到改了一半的工作树会重头做(违反 D Surgical + 浪费 token)。Handover 机制用 `runtime/<agent>-handover.md` 把"前一家做到哪儿"传给新 provider。

- [ ] **Step 1: agent-runner.sh — 检测 handover.md 存在则 prepend**

定位 Task 3.1 step 4 改造的 PROMPT_FILE 组装区域:

```bash
PROMPT_FILE="$(mktemp)"
PREAMBLE="$ROOT/.aiagents/prompts/dispatch-preamble.md"
[ -f "$PREAMBLE" ] && cat "$PREAMBLE" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
echo "---" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
cat "$SPEC" >> "$PROMPT_FILE"
```

替换为(在 spec 之前注入 handover):

```bash
PROMPT_FILE="$(mktemp)"
PREAMBLE="$ROOT/.aiagents/prompts/dispatch-preamble.md"
[ -f "$PREAMBLE" ] && cat "$PREAMBLE" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
echo "---" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"

# Handover detection (provider 切换接续场景)
HANDOVER_FILE="$RUNTIME_DIR/${AGENT}-handover.md"
if [ -f "$HANDOVER_FILE" ]; then
  cat "$HANDOVER_FILE" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"
  echo "---" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"
  event "info" "handover.md 已 prepend 到 prompt (接续派单 from $(grep -m1 'provider <prev>' "$HANDOVER_FILE" || echo unknown))"
fi

cat "$SPEC" >> "$PROMPT_FILE"
```

并在派单成功(`done` case)后归档 handover:

定位 `case "$COMPLETION" in` block,在 `done)` case 内加(在 write_state 之前):

```bash
done)
  # Archive handover.md if existed (post-success)
  if [ -f "$HANDOVER_FILE" ]; then
    local archive_dir="$RUNTIME_DIR/archive"
    mkdir -p "$archive_dir"
    local ts="$(date '+%Y%m%d-%H%M%S')"
    mv "$HANDOVER_FILE" "$archive_dir/${ts}-${AGENT}-handover.md"
    event "info" "handover.md archived to ${archive_dir}/${ts}-${AGENT}-handover.md"
  fi
  : > "$SIG_DIR/${AGENT}_done"
  ...
```

- [ ] **Step 2: agentctl.sh — `retry-other-provider` 子命令**

在已加的 `release-without-verify` case 旁边加:

```bash
retry-other-provider)
  shift
  AGENT="$1"
  [ -z "$AGENT" ] && { echo "用法: agentctl.sh retry-other-provider <backend|frontend>" >&2; exit 2; }

  # 读 events.jsonl 末尾找上次该 agent 用的 provider
  PREV_PROVIDER="$("$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" <<'PY' 2>/dev/null
import json, sys
path, agent = sys.argv[1:3]
prev = ""
try:
    with open(path, encoding='utf-8') as f:
        for line in f:
            try:
                rec = json.loads(line)
                if rec.get("agent") == agent and rec.get("provider"):
                    prev = rec["provider"]
            except Exception: pass
    print(prev)
except Exception: pass
PY
)"
  [ -z "$PREV_PROVIDER" ] && { echo "未找到 $AGENT 上次使用的 provider (events.jsonl 无记录)" >&2; exit 2; }

  # 找另一家 provider
  OTHER_PROVIDER="$("$PYTHON_BIN" - "$CONFIG_JSON" "$PREV_PROVIDER" <<'PY' 2>/dev/null
import json, sys
cfg, prev = sys.argv[1:3]
try:
    d = json.load(open(cfg, encoding='utf-8'))
    others = [k for k in d.get("providers", {}).keys() if k != prev]
    print(others[0] if others else "")
except Exception: pass
PY
)"
  [ -z "$OTHER_PROVIDER" ] && { echo "config.json providers 仅含 $PREV_PROVIDER,无可切换的另一家" >&2; exit 2; }

  # 生成 handover.md 骨架
  RUNTIME_DIR_ABS="$ROOT/.aiagents/runtime"
  mkdir -p "$RUNTIME_DIR_ABS"
  HANDOVER="$RUNTIME_DIR_ABS/${AGENT}-handover.md"

  # 找 baseline:上次 dispatch 前的 commit (从 events.jsonl 找最早的 running event)
  WORK_DIR="$("$PYTHON_BIN" - "$CONFIG_JSON" "agents.${AGENT}.dir" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    cur = d
    for p in sys.argv[2].split('.'): cur = cur[p]
    print(cur)
except Exception: pass
PY
)"
  WORK_ABS="$ROOT/$WORK_DIR"

  # 假设 baseline 是 HEAD~N,N 是上轮新 commit 数 - 用 git log 上次 dispatch 之后所有 commits
  COMMITS_LIST="$(cd "$WORK_ABS" && git log --oneline HEAD --pretty=format:"  - %h %s" -10 2>/dev/null | head -10)"
  STATUS_OUT="$(cd "$WORK_ABS" && git status --porcelain 2>/dev/null | sed 's/^/  /')"

  # 找上次失败原因(events.jsonl 末尾 message)
  FAIL_REASON="$("$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" <<'PY' 2>/dev/null
import json, sys
path, agent = sys.argv[1:3]
reason = ""
try:
    with open(path, encoding='utf-8') as f:
        for line in f:
            try:
                rec = json.loads(line)
                if rec.get("agent") == agent and rec.get("status") in ("failed", "timeout", "stale"):
                    reason = rec.get("message", "")
            except Exception: pass
    print(reason)
except Exception: pass
PY
)"

  cat > "$HANDOVER" <<EOF
# Handover: $AGENT 接续派单 (provider $PREV_PROVIDER → $OTHER_PROVIDER)

**触发**: 主 Claude 决定换 provider,前一家 $PREV_PROVIDER 失败 ($FAIL_REASON)

## 前一轮已落

- 自上次 dispatch 起的 commits:
$COMMITS_LIST

- 未 commit 改动:
$STATUS_OUT

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

  echo "已生成 handover 骨架: $HANDOVER"
  echo "next steps:"
  echo "  1. 主 Claude 跑 spec § 自检 grep 矩阵填 ## Spec 验收清单逐项状态 段"
  echo "  2. 调 /dispatch-${AGENT} --provider $OTHER_PROVIDER (或 /bugfix-${AGENT} --provider $OTHER_PROVIDER)"
  ;;
```

- [ ] **Step 3: Slash command `retry-other-provider.md`**

```markdown
---
description: Provider 切换接续 — claude 失败 → 切 codex(或反向),保任务一致性不重做
---

> Usage: /retry-other-provider <backend|frontend>
>
> 流程:
> 1. agentctl 读 events.jsonl 找上次该 agent 用的 provider
> 2. 从 config.json 找另一家 provider
> 3. 生成 `.aiagents/runtime/<agent>-handover.md` 骨架(列前一家 commits / 未提交改动 / 失败原因)
> 4. **主 Claude 待填**: 跑 spec § 自检 grep 矩阵填 ✅/❌ 每条验收点
> 5. 主 Claude 调 /dispatch-<agent> --provider <other> 派对家
> 6. runner 检测 handover.md 存在 → prepend 到 prompt → 新 provider 读到接续依据
> 7. 派单成功后 handover.md 自动归档到 `runtime/archive/`

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
bash "$ROOT/.aiagents/bin/agentctl.sh" retry-other-provider $ARGUMENTS
```
```

- [ ] **Step 4: 主 CLAUDE.md 加 § 切换编码 agent 接续流程**

在 Task 4.1 已加的 § Pre-Human Decision Gate 节后面追加:

```markdown
## ⛔ 切换编码 agent 接续流程 (Handover 机制)

**触发场景**: 编码 agent failed,且失败原因属"换家可能解决"类(API 限流 / token 配额 / sandbox 异常 / 网络抖动)。

**步骤**(主 Claude 必走):

1. 看 `events.jsonl` 末尾确认失败原因 (read,不依赖 message 关键词)
2. 决定是否值得换家:
   - ✅ 值得: rate-limit / quota / sandbox 错(provider 内禀问题)
   - ❌ 不值得: spec 错 / 业务码 bug / 测试 fail(换家也跑不通,该走 04 修复)
3. 调 `/retry-other-provider <agent>` 生成 handover.md 骨架
4. **fill 验收清单**(硬要求): 跑 spec § 自检 grep 矩阵,每条验收点填 ✅/❌
   - 不能跳过;不填直接派 → 编码 agent 没接续依据可能重做
5. 调 `/dispatch-<agent> --provider <other>` 派对家
6. 等编码 agent 完成 → 走标准 review + verify gate

**反例**(严禁):

- ❌ 看到 failed 直接 retry 同一 provider — 失败原因没解,徒劳
- ❌ 看到 failed 直接 dispatch 对家 (跳 retry-other-provider) — 没 handover,新 provider 不知接续
- ❌ retry-other-provider 后没填 ✅/❌ 直接 dispatch — 新 provider 看到空 ✅/❌ 段会重做
```

- [ ] **Step 5: 修改 Task 5.1 子目录 CLAUDE.md 模板加接续派单条款**

把 Task 5.1 step 1 / step 2 写的 backend-CLAUDE.md / frontend-CLAUDE.md 各加一节(在角色边界之后,失败上报之前):

```markdown
## 接续派单(如有)

如果你读到 `.aiagents/runtime/<agent>-handover.md`(`<agent>` = backend / frontend),**先读它再读 spec** — 这是接续派单:

- 前一家 provider 已部分完成,你是续做
- handover 列出 ✅/❌ 验收清单 — **只做 ❌ 项**
- 不重写 ✅ 项,即便你觉得能写得更好(D Surgical 硬约束)
- 续做完成时 commit 不覆盖前一轮历史(禁 git reset / amend / push -f)
- handover 末尾的"原 spec 在下一段" 标记之后才是 spec 正文,handover 优先级高于 spec
```

(此条加到 Task 5.1 的 backend-CLAUDE.md / frontend-CLAUDE.md step 内)

- [ ] **Step 6: Smoke test handover prepend logic**

```bash
cd /d/dev/ai/workspace/choseStock
mkdir -p .aiagents/runtime
cat > .aiagents/runtime/backend-handover.md <<'EOF'
# Handover: backend 接续派单 (TEST)
## 前一轮已落
- abcd1234 feat: partial work
## 验收
- ✅ §1 done
- ❌ §2 todo
EOF
mkdir -p docs/ai-agents/specs
cat > docs/ai-agents/specs/02-后端编码.md <<'EOF'
原始 spec 内容
EOF

# Run runner up to PROMPT_FILE construction (modify temporarily to print and exit)
# (For smoke test: cat handover + spec assembly)
PROMPT="$(mktemp)"
cat .aiagents/runtime/backend-handover.md >> "$PROMPT"
echo "---" >> "$PROMPT"
cat docs/ai-agents/specs/02-后端编码.md >> "$PROMPT"
cat "$PROMPT"
rm "$PROMPT"

# Cleanup
rm .aiagents/runtime/backend-handover.md
rm docs/ai-agents/specs/02-后端编码.md
```

Expected: 打印的 PROMPT 内容: handover 在前,然后 `---`,然后 spec。

- [ ] **Step 7: Commit**

```bash
cd /c/Users/mi/ai-agents-kit
git add templates/.aiagents/bin/agent-runner.sh \
        templates/.aiagents/bin/agentctl.sh \
        templates/CLAUDE.md \
        templates/.claude/commands/retry-other-provider.md
git commit -m "feat: provider 切换接续 (handover.md mechanism + retry-other-provider slash)"
```

---

### Task 4.5: Update Stop hook to fire on `ready-for-human`

**Files:**
- Modify: `templates/.aiagents/bin/stop-notify.sh`

- [ ] **Step 1: Read current stop-notify.sh**

```bash
cat templates/.aiagents/bin/stop-notify.sh
```

- [ ] **Step 2: Add new state to detection logic**

Find where it checks `done-awaiting-review` and extend to handle `ready-for-human`:

```bash
case "$state" in
  done-awaiting-review)
    echo "[Stop hook] 检测到 ${agent} 状态变化: ✅ 编码完成,请走 Karpathy 6 项审查 + Pre-Human Decision Gate"
    ;;
  claude-verifying)
    echo "[Stop hook] 检测到 ${agent} 处于 claude-verifying — 主 Claude 在跑真打验证,Lane 不需介入"
    ;;
  ready-for-human)
    echo "[Stop hook] 🟢 ${agent} 验证全过,等待 Lane 决策(收下 / 打回 / 推迟)"
    ;;
esac
```

- [ ] **Step 3: Smoke test**

Manually edit a state.json fixture and run the hook:

```bash
echo '{"backend":{"state":"ready-for-human","provider":"claude"}}' > /tmp/test_state.json
STATE_FILE=/tmp/test_state.json bash templates/.aiagents/bin/stop-notify.sh 2>&1 | head -5
```

Expected: `🟢 backend 验证全过,等待 Lane 决策...`

- [ ] **Step 4: Commit**

```bash
git add templates/.aiagents/bin/stop-notify.sh
git commit -m "feat(hook): trigger on ready-for-human + claude-verifying states"
```

---

## Phase 5 — Context isolation

### Task 5.1: Subdir CLAUDE.md templates

**Files:**
- Create: `templates/backend-CLAUDE.md`
- Create: `templates/frontend-CLAUDE.md`

- [ ] **Step 1: Write backend-CLAUDE.md**

```markdown
# backend 编码 agent — 子目录指令

> 由 ai-agents-kit 安装,不要手编辑 marker 段。
> <!-- ai-agents-kit:agent-claude-md v2 -->

## 你的角色

你是被派单执行**后端编码**任务的独立 agent。本目录(`<BACKEND_DIR>/`)是你的工作区,主 agent 在项目根另有指令(与你无关)。

## 角色边界(硬约束)

- ✅ 只读 `docs/ai-agents/specs/02-后端编码.md` 或 `docs/ai-agents/specs/04-Bug修复-backend.md`(由派单决定)
- ✅ 只在本目录及其子目录改代码 + commit
- ❌ **不读** `docs/ai-agents/reviews/` `docs/ai-agents/retrospectives/`(审查产物 / 复盘,与编码无关)
- ❌ **不读** 项目根 `CLAUDE.md`(主 agent 指令)
- ❌ **不读** `.aiagents/memory/`(主 agent 跨会话长期记忆,会污染你的上下文)
- ❌ **不读** `<FRONTEND_DIR>/`(前端目录) — 一行都不动

## 派单纪律

- 禁止 `git add -A`,只 `git add <files>`
- 禁止等价 API 互换(D Surgical)— 即便"统一风格"也不行
- 禁止自启浏览器 / 调外部网络命令(F12 由 Lane 人工验收)
- working tree 已要求派单前干净,你的 commit 单一职责
- 重写前先 `git show HEAD:<file> | sed -n '<a>,<b>p'` 看现状
- commit 前自跑 spec § 自检矩阵全部 grep / wc / find 命令,粘到 commit message 末尾

## 失败上报

- spec 与现状有矛盾立即停下,写到 `.aiagents/runtime/backend-blocked.md`,不要盲改
- 收到 spec 没明示的需求决策,停下报告,不要凭直觉扩展
- 任何外部依赖问题(npm install / pip install / DB 连不上)立即停下报告

> <!-- ai-agents-kit:agent-claude-md-end v2 -->
```

- [ ] **Step 2: Write frontend-CLAUDE.md**

Same structure, swap `backend` → `frontend`, swap `02-后端编码.md` → `03-前端编码.md`, swap `<BACKEND_DIR>` ↔ `<FRONTEND_DIR>`. Add frontend-specific 派单纪律:

```markdown
## 派单纪律 (前端额外)

- 禁止 `<script src="./xxx.jsx">` 跨文件引用 (file:// CORS 拒绝);所有 JSX 内联到 HTML
- 禁止 Google Fonts CDN (`fonts.googleapis.com` / `fonts.gstatic.com`),必须 loli.net 镜像
- 禁止改 `Object.assign(window, {...})` 命名空间冻结清单 (具体清单见 spec)
- 禁止 `shared/` 目录共享组件 — 多页之间组件复用靠"每页内联同份代码"
```

- [ ] **Step 3: Commit**

```bash
git add templates/backend-CLAUDE.md templates/frontend-CLAUDE.md
git commit -m "feat: subdir CLAUDE.md templates for coding agents (context isolation)"
```

---

### Task 5.2: `dispatch-preamble.md` cross-provider preamble

**Files:**
- Create: `templates/.aiagents/prompts/dispatch-preamble.md`

- [ ] **Step 1: Write preamble**

```markdown
# 派单纪律(由 ai-agents-kit 注入,跨 provider 共享)

你是被派单执行编码任务的 agent。请严格遵守:

1. **commit 纪律**: 禁用 `git add -A`,只 `git add <files>`。working tree 派单前已要求干净,你的 commit 应单一职责
2. **D Surgical**: 严禁等价 API 互换(如 `dataset.foo` ↔ `setAttribute('data-foo')`、`?.` ↔ `&&` 等)
3. **网络与浏览器**: 严禁自启浏览器(F12 由 Lane 人工验收)/ 调外部网络命令(curl 第三方 API / Playwright)
4. **失败上报**: spec 与现状有矛盾立即停下,写到 `.aiagents/runtime/<agent>-blocked.md`,不要盲改
5. **重写前 grep**: 整段重写 / 替换前先 `git show HEAD:<file> | sed -n '<a>,<b>p'` 看现状
6. **静态自检**: 在 commit 前自跑 spec § 自检矩阵全部 grep / wc / find 命令,粘到 commit message 末尾

派单合同正文从下一段开始:
```

- [ ] **Step 2: Commit**

```bash
git add templates/.aiagents/prompts/dispatch-preamble.md
git commit -m "feat: cross-provider dispatch preamble"
```

---

### Task 5.3: Settings.json `permissions.deny` for business dirs

**Files:**
- Modify: `templates/.claude/settings.json`

- [ ] **Step 1: Read current settings.json permissions block**

```bash
cat templates/.claude/settings.json | python -m json.tool
```

- [ ] **Step 2: Add deny entries with placeholder**

In the `permissions` object:

```json
{
  "permissions": {
    "allow": [...],
    "deny": [
      "Edit(${BACKEND_DIR}/**)",
      "Edit(${FRONTEND_DIR}/**)",
      "Write(${BACKEND_DIR}/**)",
      "Write(${FRONTEND_DIR}/**)"
    ]
  }
}
```

(Use `${BACKEND_DIR}` literal placeholder — install.sh substitutes during deployment.)

- [ ] **Step 3: Commit**

```bash
git add templates/.claude/settings.json
git commit -m "feat(settings): deny Edit/Write on business dirs (main agent guard)"
```

---

## Phase 6 — install.sh schema migration + smoke harness

### Task 6.1: Create v2 fixture project for migration test

**Files:**
- Create: `tests/fixtures/v2-project/.aiagents/config.json`
- Create: `tests/fixtures/v2-project/.aiagents/state/current.json`
- Create: `tests/fixtures/v2-project/.claude/agents.conf`
- Create: `tests/fixtures/v2-project/CLAUDE.md`
- Create: `tests/fixtures/v2-project/docs/ai-agents/specs/_keep.md`

- [ ] **Step 1: Write v2 config.json (legacy schema)**

```json
{
  "backend":  { "dir": "stock-be",  "stack": "FastAPI" },
  "frontend": { "dir": "stock-fe", "stack": "React" },
  "codex":    {
    "bin": "codex",
    "args": "--dangerously-bypass-approvals-and-sandbox",
    "timeout_seconds": 1800
  },
  "workflow": { "max_retry": 3 },
  "paths": {
    "signals": ".aiagents/signals",
    "logs": ".aiagents/logs",
    "state": ".aiagents/state",
    "memory": ".aiagents/memory",
    "specs": "docs/ai-agents/specs",
    "reviews": "docs/ai-agents/reviews",
    "retrospectives": "docs/ai-agents/retrospectives"
  }
}
```

- [ ] **Step 2: Write minimal state.json + agents.conf + CLAUDE.md**

```bash
mkdir -p tests/fixtures/v2-project/.aiagents/state
mkdir -p tests/fixtures/v2-project/.claude
mkdir -p tests/fixtures/v2-project/docs/ai-agents/specs
mkdir -p tests/fixtures/v2-project/stock-be
mkdir -p tests/fixtures/v2-project/stock-fe

cat > tests/fixtures/v2-project/.aiagents/state/current.json <<'EOF'
{"updated_at":"2026-05-09T00:00:00+08:00","backend":{"dir":"stock-be","state":"idle"},"frontend":{"dir":"stock-fe","state":"idle"}}
EOF

cat > tests/fixtures/v2-project/.claude/agents.conf <<'EOF'
BACKEND_DIR="stock-be"
FRONTEND_DIR="stock-fe"
CODEX_BIN="codex"
CODEX_ARGS="--dangerously-bypass-approvals-and-sandbox"
CODEX_TIMEOUT=1800
MAX_RETRY=3
EOF

echo "# project root" > tests/fixtures/v2-project/CLAUDE.md
echo "_keep_" > tests/fixtures/v2-project/docs/ai-agents/specs/_keep.md
```

- [ ] **Step 3: Commit fixture**

```bash
git add tests/fixtures/v2-project/
git commit -m "test: add v2 project fixture for migration tests"
```

---

### Task 6.2: install.sh — detect v2 vs v3 + migrate

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Read current install.sh structure**

```bash
grep -n "^[a-z_]*\(\)\|^# \|^MIGRATE\|^check_v" install.sh | head -40
```

- [ ] **Step 2: Add `detect_kit_version()` function**

Insert near top of script (after globals):

```bash
detect_kit_version() {
  local target="$1"
  if [ ! -d "$target/.aiagents/state" ]; then
    if [ -d "$target/docs/superpowers/specs" ]; then
      echo "v1"
    else
      echo "fresh"
    fi
    return
  fi
  if [ -f "$target/.aiagents/config.json" ]; then
    if "$PYTHON_BIN" -c "import json; d=json.load(open(\"$target/.aiagents/config.json\")); exit(0 if 'providers' in d else 1)" 2>/dev/null; then
      echo "v3"
    else
      echo "v2"
    fi
    return
  fi
  echo "v2"
}
```

- [ ] **Step 3: Add `migrate_v2_to_v3()` function**

```bash
migrate_v2_to_v3() {
  local target="$1"
  local cfg="$target/.aiagents/config.json"
  echo "[migrate v2→v3] rewriting $cfg"

  "$PYTHON_BIN" - "$cfg" <<'PY'
import json, sys
path = sys.argv[1]
old = json.load(open(path, encoding='utf-8'))

new = {
  "default_provider": "codex",
  "agents": {
    "backend":  {
      "dir":   old.get("backend", {}).get("dir", ""),
      "stack": old.get("backend", {}).get("stack", ""),
      "provider": "codex",
      "test_cmd": old.get("backend", {}).get("test_cmd", ""),
      "lint_cmd": old.get("backend", {}).get("lint_cmd", ""),
      "import_check": "",
      "smoke_endpoints": [],
    },
    "frontend": {
      "dir":   old.get("frontend", {}).get("dir", ""),
      "stack": old.get("frontend", {}).get("stack", ""),
      "provider": "codex",
      "test_cmd": old.get("frontend", {}).get("test_cmd", ""),
      "lint_cmd": old.get("frontend", {}).get("lint_cmd", ""),
      "build_cmd": "",
      "smoke_grep": [],
    },
  },
  "providers": {
    "codex":  {
      "bin":  old.get("codex", {}).get("bin", "codex"),
      "args": old.get("codex", {}).get("args", "--dangerously-bypass-approvals-and-sandbox"),
      "timeout": int(old.get("codex", {}).get("timeout_seconds", 1800)),
      "subcommand": "exec",
      "stdin_supported": True,
    },
    "claude": {
      "bin":  "claude",
      "args": "--dangerously-skip-permissions",
      "timeout": 2400,
      "subcommand": "-p",
      "stdin_supported": True,
    },
  },
  "workflow": old.get("workflow", {"max_retry": 3}),
  "paths":    old.get("paths", {}),
}

# Add new paths
new["paths"].setdefault("prompts", ".aiagents/prompts")
new["paths"].setdefault("runtime", ".aiagents/runtime")

with open(path, "w", encoding='utf-8') as f:
  json.dump(new, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY

  # Deploy subdir CLAUDE.md if missing
  for agent in backend frontend; do
    local agent_dir
    agent_dir="$("$PYTHON_BIN" -c "import json; print(json.load(open(\"$cfg\"))['agents']['$agent']['dir'])")"
    [ -z "$agent_dir" ] && continue
    [ "${agent_dir:0:1}" = "/" ] || agent_dir="$target/$agent_dir"
    if [ -d "$agent_dir" ] && [ ! -f "$agent_dir/CLAUDE.md" ]; then
      cp "$KIT_ROOT/templates/${agent}-CLAUDE.md" "$agent_dir/CLAUDE.md"
      # Substitute placeholders
      sed -i.bak "s|<BACKEND_DIR>|$(basename "$agent_dir")|g; s|<FRONTEND_DIR>|$(basename "$agent_dir")|g" "$agent_dir/CLAUDE.md"
      rm -f "$agent_dir/CLAUDE.md.bak"
      echo "[migrate v2→v3] deployed $agent_dir/CLAUDE.md"
    fi
  done

  # Deploy preamble
  mkdir -p "$target/.aiagents/prompts"
  if [ ! -f "$target/.aiagents/prompts/dispatch-preamble.md" ]; then
    cp "$KIT_ROOT/templates/.aiagents/prompts/dispatch-preamble.md" "$target/.aiagents/prompts/"
  fi

  # Deploy provider adapters
  mkdir -p "$target/.aiagents/bin/providers"
  cp "$KIT_ROOT/templates/.aiagents/bin/providers/"{_common.sh,_template.sh,codex.sh,claude.sh} "$target/.aiagents/bin/providers/"

  # Append MIGRATED.md note
  cat >> "$target/.aiagents/MIGRATED.md" <<EOF

## $(date '+%Y-%m-%d %H:%M') · v2 → v3 multi-provider 升级

- config.json schema 升级:codex.* → providers.codex.*; 加 providers.claude.*
- agents.{backend,frontend}.provider 默认 codex(行为零变化)
- 部署 BACKEND_DIR/CLAUDE.md FRONTEND_DIR/CLAUDE.md(如不存在)
- 部署 .aiagents/prompts/dispatch-preamble.md
- 部署 .aiagents/bin/providers/*.sh adapter
- state 枚举扩 claude-verifying / ready-for-human(Pre-Human Decision Gate)

下一步: 运行 \`bash .aiagents/bin/agentctl.sh status\` 验证;首次 dispatch 必盯 events.jsonl
EOF

  echo "[migrate v2→v3] complete"
}
```

- [ ] **Step 4: Hook into main install flow**

In the main install function, branch on detected version:

```bash
KIT_VERSION="$(detect_kit_version "$TARGET")"
case "$KIT_VERSION" in
  fresh) install_fresh "$TARGET" ;;
  v1)
    if [ "${MIGRATE_V1:-0}" = "1" ]; then
      migrate_v1_to_v3 "$TARGET"   # existing logic + chain to v2→v3
    else
      echo "ERROR: 检测到 v1 项目,请用 --migrate-v1 升级"
      exit 2
    fi
    ;;
  v2)
    echo "[install] 检测到 v2 项目 — 自动升级到 v3 multi-provider"
    migrate_v2_to_v3 "$TARGET"
    ;;
  v3)
    echo "[install] 检测到 v3 项目 — 跳过(已是最新)"
    ;;
esac
```

- [ ] **Step 5: Smoke test against fixture**

Create `tests/smoke/test_migrate_v2_to_v3.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
KIT="$(cd "$DIR/../.." && pwd)"

FIX="$(setup_fixture v2-project)"

# Run install (new logic should detect v2 and migrate)
bash "$KIT/install.sh" --target "$FIX" --yes 2>&1 | tee /tmp/migrate.log

# Assertions
assert_file_exists "$FIX/.aiagents/config.json" "config.json exists"
PROVIDERS=$(python -c "import json; print(','.join(json.load(open('$FIX/.aiagents/config.json'))['providers'].keys()))")
assert_eq "$PROVIDERS" "codex,claude" "providers block has codex+claude"

DEFAULT=$(python -c "import json; print(json.load(open('$FIX/.aiagents/config.json'))['default_provider'])")
assert_eq "$DEFAULT" "codex" "default_provider = codex"

BE_PROVIDER=$(python -c "import json; print(json.load(open('$FIX/.aiagents/config.json'))['agents']['backend']['provider'])")
assert_eq "$BE_PROVIDER" "codex" "backend.provider = codex (v2 fallback)"

assert_file_exists "$FIX/stock-be/CLAUDE.md" "backend subdir CLAUDE.md deployed"
assert_file_exists "$FIX/stock-fe/CLAUDE.md" "frontend subdir CLAUDE.md deployed"
assert_file_exists "$FIX/.aiagents/prompts/dispatch-preamble.md" "preamble deployed"
assert_file_exists "$FIX/.aiagents/bin/providers/codex.sh" "codex adapter deployed"
assert_file_exists "$FIX/.aiagents/bin/providers/claude.sh" "claude adapter deployed"

# Idempotency: rerun should not re-migrate
bash "$KIT/install.sh" --target "$FIX" --yes 2>&1 | grep -q "v3 — 跳过" || \
  { echo "FAIL: idempotency"; TESTS_FAILED=$((TESTS_FAILED+1)); }
[ "$?" -eq 0 ] && { echo "  ✓ idempotency on rerun"; TESTS_PASSED=$((TESTS_PASSED+1)); }

cleanup_fixture "$FIX"
report
```

Run:

```bash
chmod +x tests/smoke/test_migrate_v2_to_v3.sh
bash tests/smoke/test_migrate_v2_to_v3.sh
```

Expected: all assertions pass.

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/smoke/test_migrate_v2_to_v3.sh
git commit -m "feat(install): v2→v3 schema migration + subdir CLAUDE.md + adapters"
```

---

### Task 6.3: install.ps1 mirror

**Files:**
- Modify: `install.ps1`

- [ ] **Step 1: Mirror `detect_kit_version` and `migrate_v2_to_v3` in PowerShell**

Same logic, PowerShell syntax. Use `ConvertFrom-Json` / `ConvertTo-Json`.

- [ ] **Step 2: Smoke test on Windows**

```powershell
$fix = "C:\temp\v2-fix-$(Get-Random)"
Copy-Item -Recurse C:\Users\mi\ai-agents-kit\tests\fixtures\v2-project $fix
pwsh C:\Users\mi\ai-agents-kit\install.ps1 -Target $fix -Yes
Get-Content $fix\.aiagents\config.json | ConvertFrom-Json | Select-Object -ExpandProperty providers | Get-Member -MemberType NoteProperty | Select-Object Name
Remove-Item -Recurse $fix
```

Expected: shows `codex` and `claude` member names.

- [ ] **Step 3: Commit**

```bash
git add install.ps1
git commit -m "feat(install-ps): mirror v2→v3 migration logic"
```

---

## Phase 7 — End-to-end smoke + memory write-back

### Task 7.1: All-tests orchestrator

**Files:**
- Create: `tests/smoke/run_all.sh`

- [ ] **Step 1: Write orchestrator**

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
for t in "$DIR"/test_*.sh; do
  echo "====================================="
  echo "Running $(basename "$t")"
  echo "====================================="
  if ! bash "$t"; then
    FAILED=$((FAILED+1))
  fi
done

echo
echo "====================================="
echo "Total test files failed: $FAILED"
echo "====================================="
[ "$FAILED" -eq 0 ]
```

- [ ] **Step 2: Run all**

```bash
chmod +x tests/smoke/run_all.sh
bash tests/smoke/run_all.sh
```

Expected: exit 0, all sub-tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/run_all.sh
git commit -m "test: orchestrator for all smoke tests"
```

---

### Task 7.2: choseStock real-world dispatch (Codex baseline)

**Files:** none (validation against real project)

- [ ] **Step 1: Migrate choseStock v2 → v3**

```bash
cd /d/dev/ai/workspace/choseStock
git status -s   # ensure clean tree
bash /c/Users/mi/ai-agents-kit/install.sh --target . --yes 2>&1 | tee /tmp/cstock-migrate.log
```

Expected: log says `自动升级到 v3 multi-provider`, no errors.

- [ ] **Step 2: Verify config.json**

```bash
python -c "import json; d=json.load(open('.aiagents/config.json')); print('providers:', list(d['providers'].keys())); print('agents.backend.provider:', d['agents']['backend']['provider']); print('default:', d['default_provider'])"
```

Expected: `providers: ['codex', 'claude']`, `agents.backend.provider: codex`, `default: codex`.

- [ ] **Step 3: Verify subdir CLAUDE.md NOT overwritten if exists**

```bash
ls -la stock-be/CLAUDE.md stock-fe/CLAUDE.md 2>/dev/null
```

If they didn't exist before, they should now (deployed). If they did exist, content untouched.

- [ ] **Step 4: Test status output shows Provider column**

```bash
bash .aiagents/bin/agentctl.sh status
```

Expected: output includes a `Provider` column with `codex`/`codex`.

- [ ] **Step 5: Dry-run dispatch (don't actually start watcher)**

```bash
bash .aiagents/bin/agentctl.sh dispatch backend
ls .aiagents/signals/
cat .aiagents/signals/task_ready_backend
rm .aiagents/signals/task_ready_backend
```

Expected: signal file with JSON body containing `provider_override:""` (default).

- [ ] **Step 6: Commit choseStock migration**

```bash
cd /d/dev/ai/workspace/choseStock
git add .
git commit -m "chore: migrate ai-agents-kit v2 → v3 (multi-provider + verify gate)"
```

---

### Task 7.3: choseStock first Claude Code dispatch (real provider switch)

**Files:** none (validation)

- [ ] **Step 1: Verify Claude Code CLI available**

```bash
which claude && claude --version
```

If unavailable, install via Anthropic docs or `npm i -g @anthropic-ai/claude-code`.

- [ ] **Step 2: Create a tiny test spec**

```bash
cd /d/dev/ai/workspace/choseStock
mkdir -p docs/ai-agents/specs
cat > docs/ai-agents/specs/02-后端编码.md <<'EOF'
# 02 — multi-provider smoke test

请在 stock-be/ 内创建 `MULTI_PROVIDER_TEST.md`,内容写一行 "smoke ok: $(date)",然后 git commit。
不修改其他文件。
EOF
```

- [ ] **Step 3: Dispatch with --provider claude**

```bash
bash .aiagents/bin/agentctl.sh dispatch --provider claude --timeout 600 backend
# Watcher should pick it up. If not running, start:
bash .aiagents/bin/watch-agent.sh backend &
WATCHER_PID=$!
```

Wait for completion (poll `bash .aiagents/bin/agentctl.sh status` every 30s).

- [ ] **Step 4: Verify state + events show provider=claude**

```bash
bash .aiagents/bin/agentctl.sh status
tail -3 .aiagents/state/events.jsonl
ls stock-be/MULTI_PROVIDER_TEST.md
```

Expected:
- status shows `backend  claude  done-awaiting-review` (or `ready-for-human` if verify gate auto-ran)
- events.jsonl last 3 lines have `"provider":"claude"`
- `stock-be/MULTI_PROVIDER_TEST.md` exists, single-line content

- [ ] **Step 5: Cleanup**

```bash
kill $WATCHER_PID 2>/dev/null
cd stock-be && git log -1 --oneline   # confirm Claude wrote a commit
rm MULTI_PROVIDER_TEST.md
git add -A && git commit -m "chore: cleanup multi-provider smoke artifact"
cd ..
rm docs/ai-agents/specs/02-后端编码.md
git add -A && git commit -m "chore: remove smoke-test spec"
```

---

### Task 7.4: Write memory entries

**Files:**
- Modify: `D:\dev\ai\workspace\choseStock\.aiagents\memory\global\patterns.md`
- Modify: `D:\dev\ai\workspace\choseStock\.aiagents\memory\global\bugs.md`(if any new bugs found)

- [ ] **Step 1: Append to patterns.md**

```markdown
## 2026-05-09 · multi-provider CLI 切换 + Pre-Human Decision Gate

**场景**: ai-agents-kit v2→v3 升级,前后端编码 agent 可独立选 codex / claude(派单级覆盖),主 Claude 必经 verify gate 才推 ready-for-human。

- adapter 抽象: `providers/{name}.sh` 各实现 `provider_build_cmd` + `provider_evaluate_completion`,新增 provider 零侵入(沿 LLM provider 抽象同模式 patterns.md 2026-05-03)
- prompt 走 stdin: 突破 Codex 32KB args 上限(memory bugs.md 2026-04-28)
- 子目录 CLAUDE.md: Claude Code 在 BACKEND_DIR cwd 下读子目录 CLAUDE.md,与项目根隔离(进程 + prompt 双层)
- verify gate: done-awaiting-review → claude-verifying → ready-for-human,任一验证失败回 04 修复
- 教训复用: PG 65535 / sandbox / 32KB args / git add -A / 等价 API 互换 — 6 条 memory 教训直接 reified 到 dispatch-preamble + 子目录 CLAUDE.md
- 实战: choseStock v2→v3 升级 + 第一次 Claude Code 派单 smoke 一次过

---
```

- [ ] **Step 2: Commit memory write-back**

```bash
cd /d/dev/ai/workspace/choseStock
git add .aiagents/memory/global/patterns.md
git commit -m "docs(memory): record multi-provider + verify gate adoption pattern"
```

---

### Task 7.5: Final acceptance — run full smoke suite + close out

**Files:** none

- [ ] **Step 1: Run all kit smoke tests**

```bash
cd /c/Users/mi/ai-agents-kit
bash tests/smoke/run_all.sh
```

Expected: exit 0, all assertions pass.

- [ ] **Step 2: Tag the kit release**

```bash
git tag v3.0.0
git log --oneline | head -20
```

- [ ] **Step 3: Update kit README to mention v3**

Add a section to `README.md`:

```markdown
## v3 — Multi-Provider (2026-05-09)

- Provider abstraction: `providers/{codex,claude}.sh` adapters; gemini stub
- Per-agent default + per-dispatch override: `agents.backend.provider` + `/dispatch-backend --provider claude`
- Pre-Human Decision Gate: claude-verifying → ready-for-human; main Claude must真打跑测试 + smoke + E2E
- Coding agent context isolation: subdir CLAUDE.md + main settings.json deny `Edit/Write` on business dirs
- See [docs/designs/2026-05-09-multi-provider-design.md](docs/designs/2026-05-09-multi-provider-design.md)
```

- [ ] **Step 4: Commit + tag**

```bash
git add README.md
git commit -m "docs: README v3 highlights"
git tag -f v3.0.0
```

---

## Self-Review

Reviewing plan against spec sections:

| Spec section | Plan task |
|---|---|
| § 2 整体架构 | Task 3.1 (runner refactor), 3.2 (agentctl), 3.4 (watcher) |
| § 3 配置 Schema | Task 6.2 (migration writes new schema) |
| § 4 Adapter 接口契约 | Task 0.2 (template), 0.3 (_common.sh), 1.1 (codex), 2.1 (claude) |
| § 5 派单 Prompt 组装 | Task 5.2 (preamble), 3.1 step 4 (stdin pipe) |
| § 6 编码 agent 隔离 | Task 5.1 (subdir CLAUDE.md), 5.3 (settings deny), 4.1 (provider 同源审查纪律) |
| § 7 Pre-Human Decision Gate | Task 4.1 (CLAUDE.md 三段式 + 验证清单), 4.3 (release-without-verify), 4.4 (Stop hook) |
| § 8 文件改动清单 | Verified — every file in spec § 8.1 / § 8.2 has a creating/modifying task |
| § 9 v1/v2 兼容 | Task 6.2 (v2→v3) — note: v1→v3 chains via existing migrate_v1 + new migrate_v2_to_v3 |
| § 10 验证 / Smoke Test | Task 7.1-7.3 (8 项 smoke + 真派单 codex/claude 各一次) |
| § 11 风险与应对 | Reified in tests (e.g., Claude stdin smoke in 7.3, 429 case in test_claude_evaluate Case 4) |
| § 12 _DEFERRED | Plan does NOT implement these; correctly out of scope |

Placeholder scan: zero TODOs / TBDs in steps; every code block contains literal content.

Type/name consistency:
- `provider_build_cmd` / `provider_evaluate_completion` consistent across _template.sh, codex.sh, claude.sh, agent-runner.sh
- `PROVIDER_OVERRIDE` / `TIMEOUT_OVERRIDE` env vars consistent across agentctl.sh, watch-agent.sh, agent-runner.sh
- State enum values `done-awaiting-review` / `claude-verifying` / `ready-for-human` consistent in CLAUDE.md, stop-notify.sh, agentctl.sh

Identified gap fixed inline: Task 6.2 step 5 needed proper assertion for idempotency check; added.

---

## Phase order rationale

Phases are ordered so each ends with a working, testable system:

- After Phase 0: tests harness up, contract documented
- After Phase 1: existing v2 dispatch still works (backward-compat path in agent-runner)
- After Phase 2: claude.sh ready but unused (no agent.provider points to it yet)
- After Phase 3: dispatching with `--provider claude` works against v2 fixture (using v2 fallback) — provider switching live
- After Phase 4: verify gate live, state enum extended
- After Phase 5: context isolation deployed
- After Phase 6: clean v2→v3 migration on real fixture
- After Phase 7: choseStock real-world validated
