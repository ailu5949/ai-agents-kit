#!/usr/bin/env bash
# templates/.aiagents/bin/providers/claude.sh
# Claude Code CLI adapter for ai-agents-kit.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

provider_build_cmd() {
  # Claude Code reads stdin when no prompt arg is given to -p.
  # --output-format stream-json --verbose: 每个工具调用 / 文本块实时输出到 stdout
  # (由 runner tee 进 log),解决 claude -p 默认非流式痛点(主 Claude 看不到子 claude 进度节点)。
  # 没这两个 flag,claude 会等所有动作完成后才一次性输出 — Lane 卡在 watcher "🔔 检测到新任务" 提示后
  # 长时间黑盒,无法判断 claude 在跑还是 hang。stream-json 解决此痛点(2026-05-10 实战验证)。
  # filter-output.sh 不识别 JSON line 也无害(原样落盘,主 Claude 可 grep / jq 过滤)。
  echo "cd '$WORK_ABS' && '$PROVIDER_BIN' -p $PROVIDER_ARGS --output-format stream-json --verbose"
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
