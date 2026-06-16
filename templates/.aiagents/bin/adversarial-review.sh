#!/usr/bin/env bash
# ai-agents-kit v3.7: 对抗性审查 (Adversarial Review)。
#
# 用一个**异构 provider**(默认 codex)在主 Claude 真打验证通过后, 对编码 agent 的
# 交付做独立"找茬"审查 — 防"同体审查盲区"(主 Claude 既写 02/03 spec 又审, 理解偏了
# 也会按自己的偏判 pass)。
#
# 用法:
#   bash adversarial-review.sh <backend|frontend> [--since <ref>] [--provider <name>]
#
# 流程:
#   1. resolve reviewer provider (默认 config.json workflow.adversarial_review.provider, 缺省 codex)
#      —— 若 reviewer == 编码 agent 的 provider, 警告 (异构性丢失) 但继续
#   2. diff 范围: <baseline>..HEAD, scoped 到 agent 工作目录
#      baseline 来源: runtime/<agent>.review-base (agent-runner 落) → 缺则 HEAD~1 + 警告
#      也可 --since <ref> 显式指定
#   3. 构建 REFUTE 提示: 派单 spec + 设计文档(如有) + git diff + 找茬指令(默认有罪)
#   4. 跑 reviewer (codex exec / claude -p) 独立审查 — 它自己读文件/跑 git, 不信编码 agent 自述
#   5. 落报告到 reviews/adversarial-<agent>-<ts>.md, grep "VERDICT: PASS|FAIL"
#   6. exit 0 (PASS) / 1 (FAIL/有问题) / 2 (用法错) / 5 (reviewer 未就绪)
#
# 主 Claude 是最终仲裁者: 读报告, PASS → ready-for-human; FAIL → 问题并入 04 修复 → 派回。
# (本脚本只产证据 + 给信号, 不自动改 state, 不自动派单。)

set -uo pipefail

AGENT=""
SINCE_REF=""
PROVIDER_FLAG=""
FORCE=0          # --force: 无视 min_diff_lines 阈值, 强制跑 (小改动也审)
STRICT=0         # --strict: 临时把 fail_on 提到 any (中低危也打回)
_USAGE="用法: adversarial-review.sh <backend|frontend> [--since <ref>] [--provider <name>] [--force] [--strict]"
while [ $# -gt 0 ]; do
  case "$1" in
    backend|frontend) AGENT="$1"; shift ;;
    --since) shift; SINCE_REF="${1:-}"; shift ;;
    --provider) shift; PROVIDER_FLAG="${1:-}"; shift ;;
    --force) FORCE=1; shift ;;
    --strict) STRICT=1; shift ;;
    *) echo "未知参数: $1" >&2; echo "$_USAGE" >&2; exit 2 ;;
  esac
done
[ "$AGENT" = backend ] || [ "$AGENT" = frontend ] || { echo "$_USAGE" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_JSON="$ROOT/.aiagents/config.json"
SPEC_DIR="$ROOT/docs/ai-agents/specs"
REVIEW_DIR="$ROOT/docs/ai-agents/reviews"
RUNTIME_DIR="$ROOT/.aiagents/runtime"
STATE_DIR="$ROOT/.aiagents/state"
BIN_DIR="$ROOT/.aiagents/bin"
mkdir -p "$REVIEW_DIR" "$RUNTIME_DIR"

PYTHON_BIN=""
for c in python python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PYTHON_BIN="$c"; break; fi
done
[ -n "$PYTHON_BIN" ] || { echo "缺少可用 python" >&2; exit 5; }
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# ---------- config 读取 ----------
cfg() {
  local jpath="$1" def="${2:-}"
  [ -f "$CONFIG_JSON" ] || { echo "$def"; return; }
  local v
  v="$("$PYTHON_BIN" - "$CONFIG_JSON" "$jpath" <<'PY' 2>/dev/null || true
import json, sys
try:
    cur = json.load(open(sys.argv[1], encoding="utf-8"))
    for p in sys.argv[2].split("."):
        cur = cur[p]
    if isinstance(cur, bool):
        print("true" if cur else "false")
    else:
        print(cur)
except Exception:
    pass
PY
)"
  [ -n "$v" ] && echo "$v" || echo "$def"
}

# ---------- v3.9 三旋钮配置 ----------
# 1) 选择性触发: 改动行数 < min_diff_lines 直接跳过 (不跑 codex), 省 token + 时间
MIN_DIFF_LINES="$(cfg "workflow.adversarial_review.min_diff_lines" "40")"
case "$MIN_DIFF_LINES" in ''|*[!0-9]*) MIN_DIFF_LINES=40 ;; esac
# 2) 严重度门: high=只有高危/违 spec 才 FAIL (默认, 中低危降级成建议不打回); any=任何问题都 FAIL
FAIL_ON="$(cfg "workflow.adversarial_review.fail_on" "high")"
[ "$STRICT" = 1 ] && FAIL_ON="any"
# 3) 降配: codex 推理强度 (medium 够审查, 省于默认 xhigh); 空=不覆盖走 codex 自身默认
REASONING_EFFORT="$(cfg "workflow.adversarial_review.reasoning_effort" "medium")"

# ---------- reviewer provider 解析 ----------
REVIEWER="$PROVIDER_FLAG"
[ -z "$REVIEWER" ] && REVIEWER="$(cfg "workflow.adversarial_review.provider" "codex")"
[ -z "$REVIEWER" ] && REVIEWER="codex"

# 编码 agent 的 provider (用于异构性检查)
CODER_PROVIDER="$(cfg "agents.${AGENT}.provider" "")"
[ -z "$CODER_PROVIDER" ] && CODER_PROVIDER="$(cfg "default_provider" "codex")"
if [ "$REVIEWER" = "$CODER_PROVIDER" ]; then
  echo "⚠️  对抗审查 reviewer ($REVIEWER) 与编码 agent provider ($CODER_PROVIDER) 相同 — 异构性丢失,审查独立性下降。" >&2
  echo "    建议: 编码用 claude 时 reviewer 用 codex(反之亦然)。改 config.json workflow.adversarial_review.provider。" >&2
fi

REVIEWER_BIN="$(cfg "providers.${REVIEWER}.bin" "$REVIEWER")"
REVIEWER_ARGS="$(cfg "providers.${REVIEWER}.args" "")"
REVIEWER_MODEL="$(cfg "providers.${REVIEWER}.model" "")"
# args 兜底(与 agent-runner 一致)
[ -z "$REVIEWER_ARGS" ] && [ "$REVIEWER" = codex ]  && REVIEWER_ARGS="--sandbox danger-full-access --skip-git-repo-check"
[ -z "$REVIEWER_ARGS" ] && [ "$REVIEWER" = claude ] && REVIEWER_ARGS="--dangerously-skip-permissions"

command -v "$REVIEWER_BIN" >/dev/null 2>&1 || {
  echo "❌ reviewer CLI 未就绪: $REVIEWER_BIN (provider=$REVIEWER)" >&2
  echo "   装好后重试, 或改 config.json workflow.adversarial_review.provider 换 reviewer。" >&2
  exit 5
}

# ---------- 工作目录 + diff 范围 ----------
WORK_DIR="$(cfg "agents.${AGENT}.dir" "$AGENT")"
case "$WORK_DIR" in
  /*|[A-Za-z]:*) WORK_ABS="$WORK_DIR" ;;
  *) WORK_ABS="$ROOT/$WORK_DIR" ;;
esac
[ -d "$WORK_ABS" ] || { echo "❌ 工作目录不存在: $WORK_ABS" >&2; exit 2; }

BASE=""
if [ -n "$SINCE_REF" ]; then
  BASE="$SINCE_REF"
elif [ -f "$RUNTIME_DIR/${AGENT}.review-base" ]; then
  BASE="$(head -1 "$RUNTIME_DIR/${AGENT}.review-base" 2>/dev/null | tr -d '[:space:]')"
fi
# 校验 BASE 是有效 ref; 无效/缺失 → HEAD~1 兜底
if [ -z "$BASE" ] || ! git -C "$ROOT" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1; then
  if git -C "$ROOT" rev-parse --verify "HEAD~1^{commit}" >/dev/null 2>&1; then
    echo "⚠️  无有效 baseline(runtime/${AGENT}.review-base 缺失或失效), 回退到 HEAD~1。如需精确范围用 --since <ref>。" >&2
    BASE="HEAD~1"
  else
    echo "⚠️  仓库提交不足(无 HEAD~1), 审查全部已跟踪改动 vs 空树。" >&2
    BASE="$(git -C "$ROOT" hash-object -t tree /dev/null 2>/dev/null || echo HEAD)"
  fi
fi

# diff scoped 到 agent 工作目录(相对 ROOT 的路径)
REL_DIR="${WORK_ABS#$ROOT/}"
DIFF_TEXT="$(git -C "$ROOT" diff "$BASE" HEAD -- "$REL_DIR" 2>/dev/null)"
DIFF_STAT="$(git -C "$ROOT" diff --stat "$BASE" HEAD -- "$REL_DIR" 2>/dev/null)"
if [ -z "$DIFF_TEXT" ]; then
  # 可能改动未提交(stale 路径代 commit 前) — 退而审查 working tree
  DIFF_TEXT="$(git -C "$ROOT" diff HEAD -- "$REL_DIR" 2>/dev/null)"
  DIFF_STAT="$(git -C "$ROOT" diff --stat HEAD -- "$REL_DIR" 2>/dev/null)"
fi
[ -n "$DIFF_TEXT" ] || {
  echo "⚠️  $BASE..HEAD 在 $REL_DIR 下无 diff — 没有可审查的改动。确认 agent 已 commit 或用 --since。" >&2
  exit 2
}

# ---------- 旋钮 1: 选择性触发 — 小改动直接跳过, 不烧 codex ----------
# 统计本轮变更行数(diff 里 +/- 开头但排除 +++/--- 文件头)
CHANGED_LINES="$(printf '%s\n' "$DIFF_TEXT" | grep -cE '^[+-]([^+-]|$)' 2>/dev/null || echo 0)"
if [ "$FORCE" != 1 ] && [ "$CHANGED_LINES" -lt "$MIN_DIFF_LINES" ]; then
  echo "⏭️  改动仅 ${CHANGED_LINES} 行 (< 阈值 ${MIN_DIFF_LINES}) — 跳过对抗审查 (琐碎改动)。"
  echo "    要强制审查: 加 --force;要改阈值: config.json workflow.adversarial_review.min_diff_lines"
  # 落一条轻量 SKIPPED 报告 + event, 让主 Claude / 日志有据可查
  TS="$(date '+%Y%m%d-%H%M%S')"
  SKIP_REPORT="$REVIEW_DIR/adversarial-${AGENT}-${TS}.md"
  {
    echo "# 对抗审查 · $AGENT · $TS · SKIPPED"
    echo
    echo "- 改动行数 ${CHANGED_LINES} < 阈值 ${MIN_DIFF_LINES} → 选择性跳过 (未跑 reviewer, 零 token)"
    echo "- diff 范围: \`$BASE..HEAD\` (scope: \`$REL_DIR/\`)"
    echo "- 强制审查: \`/adversarial-review $AGENT --force\`"
  } > "$SKIP_REPORT"
  "$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" "$REVIEWER" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
path, agent, reviewer = sys.argv[1:4]
os.makedirs(os.path.dirname(path), exist_ok=True)
rec = {"time": datetime.datetime.now().astimezone().isoformat(), "agent": agent,
       "provider": reviewer, "status": "adversarial-review", "message": "verdict=SKIPPED (below min_diff_lines)"}
open(path, "a", encoding="utf-8").write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
  echo "  裁决: ⏭️ SKIPPED — 主 Claude 视为通过, 直接推 ready-for-human"
  exit 0
fi

# diff 过大保护(codex args/上下文上限): 截断到 ~120KB, 提示 reviewer 自己 git diff 补全
DIFF_BYTES="$(printf '%s' "$DIFF_TEXT" | wc -c)"
DIFF_TRUNCATED=0
if [ "$DIFF_BYTES" -gt 120000 ]; then
  DIFF_TEXT="$(printf '%s' "$DIFF_TEXT" | head -c 120000)"
  DIFF_TRUNCATED=1
fi

# ---------- spec / 设计 收集 ----------
if [ "$AGENT" = backend ]; then
  SPEC="$SPEC_DIR/02-后端编码.md"; [ -f "$SPEC" ] || SPEC="$SPEC_DIR/02-backend.md"
else
  SPEC="$SPEC_DIR/03-前端编码.md"; [ -f "$SPEC" ] || SPEC="$SPEC_DIR/03-frontend.md"
fi
DESIGN="$SPEC_DIR/01.5-设计.md"; [ -f "$DESIGN" ] || DESIGN="$SPEC_DIR/01.5-design.md"
TESTCASES="$SPEC_DIR/01.6-测试用例.md"; [ -f "$TESTCASES" ] || TESTCASES="$SPEC_DIR/01.6-test-cases.md"
REQ="$SPEC_DIR/01-需求.md"; [ -f "$REQ" ] || REQ="$SPEC_DIR/01-requirements.md"

# ---------- 严重度门: 据 FAIL_ON 调立场 + 裁决规则 ----------
if [ "$FAIL_ON" = "any" ]; then
  STANCE_TEXT="# 立场: 严格 (strict, default-reject)
- 假设这份交付**有问题**, 把问题找出来。**任何**严重度的问题(含中/低)都算不通过。
- 不确定某点是否达标 → 判 FAIL 并说明疑点。"
  VERDICT_RULE="出现**任何**严重度(高/中/低)问题, 或 spec 验收点未满足 → FAIL;完全无问题才 PASS。"
else
  STANCE_TEXT="# 立场: 抓大放小 (只拦高危, 减少无谓返工)
- 认真找问题, 但**只有 [高] 严重度问题、或 spec 验收点确实未实现, 才判 FAIL**。
- [中]/[低] 问题(风格、小优化、非阻塞建议)照常列出来供参考, 但**不影响裁决**(仍 PASS)。
- 判 [高] 的标准要克制: 真能导致 bug / 数据错误 / 安全问题 / spec 验收点缺失才算高; 拿不准是高还是中 → 算中(不打回)。
- 目的: 别因为吹毛求疵触发一整轮重做, 把返工留给真正该返工的问题。"
  VERDICT_RULE="仅当存在 [高] 严重度问题、或 spec 验收点未实现 → FAIL;只有 [中]/[低] 问题时 → **PASS**(问题列为建议)。"
fi

# ---------- 构建 REFUTE 提示 ----------
PROMPT_FILE="$(mktemp)"
{
  cat <<EOF
你是 ai-agents-kit 的**对抗性审查员 (Adversarial Reviewer)**, provider=$REVIEWER。
你与写这段代码的编码 agent 是**异构的两个脑子** — 你的职责是独立"找茬", 不是确认。

$STANCE_TEXT
- 不要复述编码 agent 的自述 / commit message 的"我全过了" — 那不是证据。
- 你**只读不改**: 可以读任意文件、跑 git/grep/读测试, 但**禁止修改任何业务代码**。只输出审查报告到 stdout。

# 审查维度 (逐项给结论 + 证据, 每条问题标 [高]/[中]/[低])
1. **spec 符合度**: 派单 spec(下方)每条验收点, 代码是否真的实现? 漏哪条?(漏验收点=高)
2. **正确性**: 边界条件 / 空值 / 异常路径 / 并发 / 错误处理有没有漏。读实际代码, 别信注释。
3. **范围越界 (D Surgical)**: diff 里有没有 spec 没点名的改动 / 顺手重构 / 等价 API 互换 / 重命名。
4. **测试真实性**: 测试是否只覆盖快乐路径? 有没有 assert 形同虚设 / mock 掉了被测逻辑 / skip 关键用例?
5. **隐藏债**: TODO/FIXME/写死值/被注释掉的代码/吞异常(except: pass)。

# 输出格式 (markdown, 直接 stdout)
## 对抗审查 · $AGENT · reviewer=$REVIEWER

### 发现的问题
(逐条: [高/中/低] [维度] 文件:行 — 问题描述 + 为什么是问题 + 证据)
(没问题就写"未发现问题", 但你应该已经尽力找过)

### 逐维度结论
- spec 符合度 / 正确性 / 范围 / 测试 / 隐藏债: 各一句

### 最终裁决
(裁决规则: $VERDICT_RULE)
(最后一行**必须**是下面之一, 供脚本解析:)
VERDICT: PASS
或
VERDICT: FAIL

---
# 派单 spec (编码 agent 本应实现的)
EOF
  if [ -f "$REQ" ]; then echo; echo "## 需求 ($REQ)"; echo; cat "$REQ"; fi
  if [ -f "$DESIGN" ]; then echo; echo "## 设计 ($DESIGN)"; echo; cat "$DESIGN"; fi
  if [ -f "$TESTCASES" ]; then echo; echo "## 测试用例 ($TESTCASES)"; echo; cat "$TESTCASES"; fi
  if [ -f "$SPEC" ]; then echo; echo "## 编码合同 ($SPEC)"; echo; cat "$SPEC"; fi
  echo
  echo "---"
  echo "# 实际交付 git diff ($BASE..HEAD, 限 $REL_DIR/)"
  echo
  echo '```diff'
  echo "$DIFF_STAT"
  echo "..."
  echo "$DIFF_TEXT"
  echo '```'
  if [ "$DIFF_TRUNCATED" = 1 ]; then
    echo
    echo "> ⚠️ diff 超 120KB 已截断。请你自己在工作目录跑 \`git diff $BASE HEAD -- $REL_DIR\` 看完整改动。"
  fi
  echo
  echo "现在开始审查。记住裁决规则, 最后一行输出 VERDICT: PASS 或 VERDICT: FAIL。"
} > "$PROMPT_FILE"

# ---------- 跑 reviewer ----------
TS="$(date '+%Y%m%d-%H%M%S')"
REPORT="$REVIEW_DIR/adversarial-${AGENT}-${TS}.md"
RAW_LOG="$ROOT/.aiagents/logs/adversarial-${AGENT}-${TS}.log"
# v3.8: 稳定路径 live log — 供 `agentctl logs review` / `logs all` 实时 tail -F (每轮覆盖)
LIVE_LOG="$ROOT/.aiagents/logs/adversarial-${AGENT}.log"
mkdir -p "$(dirname "$RAW_LOG")"
{
  echo "============================================================"
  echo "🔍 对抗审查 · $AGENT · reviewer=$REVIEWER · $TS"
  echo "   diff=$BASE..HEAD scope=$REL_DIR/"
  echo "============================================================"
} > "$LIVE_LOG"

model_arg=""
[ -n "$REVIEWER_MODEL" ] && model_arg="--model $REVIEWER_MODEL"

echo "🔍 对抗审查启动: agent=$AGENT reviewer=$REVIEWER diff=$BASE..HEAD (${CHANGED_LINES} 行) scope=$REL_DIR"
echo "   旋钮: fail_on=$FAIL_ON · reasoning=${REASONING_EFFORT:-default} · min_diff_lines=$MIN_DIFF_LINES"
echo "   报告将落: $REPORT"
echo "   实时跟随: bash .aiagents/bin/agentctl.sh logs review  (或 logs $AGENT adversarial)"

# v3.9 旋钮 3: 降配推理强度 (codex). 审查要广度不要 xhigh 深推理 — 省时省 token。
# 非 --strict-config 下未知 key 也不硬报错, 安全。空 REASONING_EFFORT 则不覆盖。
effort_arg=""
if [ -n "$REASONING_EFFORT" ] && [ "$REVIEWER" = codex ]; then
  effort_arg="-c model_reasoning_effort=\"$REASONING_EFFORT\""
fi

# reviewer 在 ROOT 运行(能读整个 repo + 跑 git diff)
case "$REVIEWER" in
  codex)
    REVIEW_CMD="cd '$ROOT' && '$REVIEWER_BIN' exec $REVIEWER_ARGS $effort_arg $model_arg -"
    ;;
  claude)
    # claude 用 -p + stdin; 带 v3.5.1 隔离(防 user 插件污染) + 流式关掉(只要最终文本)
    REVIEW_CMD="cd '$ROOT' && '$REVIEWER_BIN' -p $REVIEWER_ARGS $model_arg --setting-sources project,local --disallowed-tools Skill AskUserQuestion"
    ;;
  *)
    # 未知 provider: 尝试 codex 风格
    REVIEW_CMD="cd '$ROOT' && '$REVIEWER_BIN' exec $REVIEWER_ARGS $effort_arg $model_arg -"
    ;;
esac

REVIEW_TIMEOUT="$(cfg "workflow.adversarial_review.timeout" "900")"
[ -z "$REVIEW_TIMEOUT" ] && REVIEW_TIMEOUT="900"

set +e
# tee 同时落: 终端 + 时间戳 raw (历史) + 稳定 live log (供 logs review 实时跟随, append)
if command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC2002
  cat "$PROMPT_FILE" | timeout "$REVIEW_TIMEOUT" bash -c "$REVIEW_CMD" 2>&1 | tee "$RAW_LOG" | tee -a "$LIVE_LOG"
else
  # shellcheck disable=SC2002
  cat "$PROMPT_FILE" | bash -c "$REVIEW_CMD" 2>&1 | tee "$RAW_LOG" | tee -a "$LIVE_LOG"
fi
rc=${PIPESTATUS[1]}
set -e
rm -f "$PROMPT_FILE"

# ---------- 整理报告 + 解析裁决 ----------
{
  echo "# 对抗审查报告 · $AGENT · $TS"
  echo
  echo "- **reviewer provider**: $REVIEWER ($REVIEWER_BIN${REVIEWER_MODEL:+ , model=$REVIEWER_MODEL})"
  echo "- **编码 agent provider**: $CODER_PROVIDER"
  echo "- **diff 范围**: \`$BASE..HEAD\` (scope: \`$REL_DIR/\`)"
  [ "$DIFF_TRUNCATED" = 1 ] && echo "- **注意**: diff 超 120KB 已截断, reviewer 被要求自行补全"
  echo "- **reviewer exit code**: $rc"
  echo
  echo "---"
  echo
  cat "$RAW_LOG"
} > "$REPORT"

# 从原始输出 grep 裁决(取最后一个 VERDICT 行)
VERDICT="$(grep -iE '^[[:space:]>*-]*VERDICT:[[:space:]]*(PASS|FAIL)' "$RAW_LOG" 2>/dev/null | tail -1 | grep -ioE 'PASS|FAIL' | tail -1 | tr '[:lower:]' '[:upper:]')"

# 写 event(若 agentctl 的 event 不可用, 直接追加 events.jsonl)
"$PYTHON_BIN" - "$STATE_DIR/events.jsonl" "$AGENT" "$REVIEWER" "${VERDICT:-UNKNOWN}" "$REPORT" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
path, agent, reviewer, verdict, report = sys.argv[1:6]
os.makedirs(os.path.dirname(path), exist_ok=True)
rec = {
    "time": datetime.datetime.now().astimezone().isoformat(),
    "agent": agent,
    "provider": reviewer,
    "status": "adversarial-review",
    "message": f"verdict={verdict} report={os.path.basename(report)}",
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

{
  echo
  echo "============================================================"
  echo "  对抗审查完成: agent=$AGENT reviewer=$REVIEWER  裁决=${VERDICT:-UNKNOWN}"
  echo "  报告: $REPORT"
  echo "============================================================"
} | tee -a "$LIVE_LOG"

case "$VERDICT" in
  PASS)
    echo "  裁决: ✅ PASS" | tee -a "$LIVE_LOG"
    exit 0
    ;;
  FAIL)
    echo "  裁决: ❌ FAIL — 主 Claude 须读报告, 把问题并入 04 修复 → 派回编码 agent" | tee -a "$LIVE_LOG"
    exit 1
    ;;
  *)
    echo "  裁决: ⚠️ 未解析到 VERDICT(reviewer rc=$rc) — 主 Claude 必须人工读报告判定, 不得默认通过" | tee -a "$LIVE_LOG"
    exit 3
    ;;
esac
