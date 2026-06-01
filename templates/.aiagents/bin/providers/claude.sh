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
  # v3.5.1 (2026-05-29): 隔离子 agent 会话, 防 user 级插件污染.
  #   --setting-sources project,local : 排除 user 源 → 不加载 ~/.claude 里启用的
  #       superpowers 插件 (其 SessionStart hook 注入 "you MUST use Skill / brainstorm /
  #       ask questions", 被 Opus 4.8 凌驾于派单 spec 之上 → 编码 agent 退化成 orchestrator,
  #       狂调 Skill/AskUserQuestion 不落键 — choseStock P29-1-sse.e F4 实战 4 轮空转教训).
  #       OAuth 鉴权走 keychain 不依赖 settings 源, 不受影响 (smoke 验证 PONG/exit 0).
  #   --disallowed-tools Skill AskUserQuestion : 双保险, 即便注入仍在也调不动这俩.
  #   注意: 不能用 --bare — 它强制 ANTHROPIC_API_KEY 鉴权, 不支持 OAuth, 会搞挂订阅登录.
  local isolation_args="--setting-sources project,local --disallowed-tools Skill AskUserQuestion"
  echo "cd '$WORK_ABS' && '$PROVIDER_BIN' -p $PROVIDER_ARGS $model_arg $isolation_args --output-format stream-json --verbose 2>&1 | tee -a '${LOG_FILE}.raw' | '$PYTHON_BIN' '$pretty_filter'"
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
