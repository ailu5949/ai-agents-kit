#!/usr/bin/env bash
# ai-agents-kit v3.6: 移动端推送层 — 编码 agent 完成/失败/超时时推手机。
#
# 用法(由 agent-runner.sh background spawn,也可手动测试):
#   bash notify-push.sh <agent> <status> <message> <project>
#   bash notify-push.sh backend done "claude 完成, 等审查" myproject
#
# 配置(.aiagents/config.json):
#   "notify": {
#     "push": {
#       "provider": "serverchan",          // serverchan | pushplus | bark | ntfy | ""(关)
#       "key": "SCT123456...",             // serverchan SendKey / pushplus token / bark device key
#       "url": "",                         // bark 自建服务器根 / ntfy topic 完整 URL(如 https://ntfy.sh/my-topic)
#       "events": ["done","failed","timeout","stale"]   // 推哪些事件,缺省全推
#     }
#   }
#
# 四通道:
#   serverchan — Server酱 (微信推送, 国内最顺): https://sct.ftqq.com
#   pushplus   — PushPlus (微信推送):           https://www.pushplus.plus
#   bark       — Bark (iOS 原生推送):           https://bark.day.app
#   ntfy       — ntfy (安卓/自建, 支持 action): https://ntfy.sh
#
# 设计原则(与 notify-toast.ps1 一致):
#   - provider 未配置 → 静默 exit 0(不影响主流程)
#   - curl 失败 / 网络抖动 → 静默(--max-time 10 防卡死 runner)
#   - 不在此脚本内做重试 — 推送是 best-effort 辅助通道, toast/Stop hook 仍是主回路

set -uo pipefail

AGENT="${1:-agent}"
STATUS="${2:-info}"
MESSAGE="${3:-}"
PROJECT="${4:-project}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_JSON="$ROOT/.aiagents/config.json"
[ -f "$CONFIG_JSON" ] || exit 0

command -v curl >/dev/null 2>&1 || exit 0

PYTHON_BIN=""
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "pass" >/dev/null 2>&1; then
    PYTHON_BIN="$candidate"; break
  fi
done
[ -n "$PYTHON_BIN" ] || exit 0
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# 一次性读出 push 配置(provider|key|url|events, tab 分隔)
PUSH_CFG="$("$PYTHON_BIN" - "$CONFIG_JSON" <<'PY' 2>/dev/null || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
    p = (cfg.get("notify") or {}).get("push") or {}
    provider = (p.get("provider") or "").strip().lower()
    key = (p.get("key") or "").strip()
    url = (p.get("url") or "").strip()
    events = p.get("events") or ["done", "failed", "timeout", "stale"]
    print("\t".join([provider, key, url, ",".join(events)]))
except Exception:
    pass
PY
)"
PROVIDER="$(echo "$PUSH_CFG" | cut -f1)"
KEY="$(echo "$PUSH_CFG" | cut -f2)"
URL="$(echo "$PUSH_CFG" | cut -f3)"
EVENTS="$(echo "$PUSH_CFG" | cut -f4)"

[ -n "$PROVIDER" ] || exit 0

# 事件过滤: STATUS 不在 events 列表里就不推
case ",$EVENTS," in
  *",$STATUS,"*) ;;
  *) exit 0 ;;
esac

# 标题 + 正文(带下一步建议, 与 toast 文案对齐)
TITLE="[$PROJECT] $AGENT $STATUS"
case "$STATUS" in
  done)    NEXT="回到 Claude Code 审查" ;;
  stale)   NEXT="work 已落, 回去代 commit + 审查" ;;
  failed)  NEXT="查 events.jsonl + log, 必要时 /retry-other-provider" ;;
  timeout) NEXT="跑 agentctl doctor 看诊断" ;;
  *)       NEXT="" ;;
esac
BODY="$MESSAGE"
[ -n "$NEXT" ] && BODY="$MESSAGE
→ $NEXT"

# URL-encode helper(serverchan/bark 走 query/path 时用)
urlenc() {
  "$PYTHON_BIN" -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

case "$PROVIDER" in
  serverchan)
    # Server酱: POST https://sctapi.ftqq.com/<SendKey>.send
    [ -n "$KEY" ] || exit 0
    curl -sS --max-time 10 -o /dev/null \
      -d "title=$(urlenc "$TITLE")" \
      --data-urlencode "desp=$BODY" \
      "https://sctapi.ftqq.com/${KEY}.send" >/dev/null 2>&1 || true
    ;;
  pushplus)
    # PushPlus: POST http://www.pushplus.plus/send (json)
    [ -n "$KEY" ] || exit 0
    "$PYTHON_BIN" - "$KEY" "$TITLE" "$BODY" <<'PY' >/dev/null 2>&1 || true
import json, sys, urllib.request
key, title, body = sys.argv[1:4]
req = urllib.request.Request(
    "https://www.pushplus.plus/send",
    data=json.dumps({"token": key, "title": title, "content": body.replace("\n", "<br>"), "template": "html"}).encode(),
    headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10)
PY
    ;;
  bark)
    # Bark: GET <server>/<device_key>/<title>/<body>  (server 默认官方 api.day.app)
    [ -n "$KEY" ] || exit 0
    BARK_BASE="${URL:-https://api.day.app}"
    BARK_BASE="${BARK_BASE%/}"
    curl -sS --max-time 10 -o /dev/null \
      "${BARK_BASE}/${KEY}/$(urlenc "$TITLE")/$(urlenc "$BODY")?group=ai-agents" >/dev/null 2>&1 || true
    ;;
  ntfy)
    # ntfy: POST <topic url>  (url 必填, 如 https://ntfy.sh/my-secret-topic)
    [ -n "$URL" ] || exit 0
    PRIORITY="default"
    case "$STATUS" in failed|timeout) PRIORITY="high" ;; esac
    curl -sS --max-time 10 -o /dev/null \
      -H "Title: $TITLE" \
      -H "Priority: $PRIORITY" \
      -H "Tags: robot" \
      -d "$BODY" \
      "$URL" >/dev/null 2>&1 || true
    ;;
  *)
    exit 0
    ;;
esac

exit 0
