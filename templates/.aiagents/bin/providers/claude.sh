#!/usr/bin/env bash
# templates/.aiagents/bin/providers/claude.sh
# Claude Code CLI adapter for ai-agents-kit.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

provider_build_cmd() {
  # Claude Code reads stdin when no prompt arg is given to -p.
  #
  # 输出处理双流(2026-05-10 v3.0.2):
  #   1. raw stream-json 实时 tee 到 ${LOG_FILE}.raw — audit / debug / jq 后处理用
  #   2. _stream_json_pretty.py 转换成"💬 / 🔧 / ✅"人眼版 → 主 LOG_FILE(Lane / 主 Claude tail 这个)
  #
  # 没 stream-json 时 claude -p 默认非流式 — 等所有动作完成后才一次性输出,
  # Lane 卡在 watcher "🔔 检测到新任务" 提示后长时间黑盒。
  # stream-json 让每个工具调用 / 文本块实时进 log,但 raw JSON 人眼读累 — 所以用 pretty filter 转。
  local pretty_filter="$BIN_DIR/providers/_stream_json_pretty.py"
  # v3.4.1: --model 支持 (e.g. opus / sonnet / haiku 或完整模型名)
  # PROVIDER_MODEL 来源优先级: dispatch --model flag > agents.<a>.model > providers.claude.model > 空 (CLI 用默认)
  local model_arg=""
  [ -n "${PROVIDER_MODEL:-}" ] && model_arg="--model $PROVIDER_MODEL"
  echo "cd '$WORK_ABS' && '$PROVIDER_BIN' -p $PROVIDER_ARGS $model_arg --output-format stream-json --verbose 2>&1 | tee -a '${LOG_FILE}.raw' | '$PYTHON_BIN' '$pretty_filter'"
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
