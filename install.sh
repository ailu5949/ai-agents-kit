#!/usr/bin/env bash
# ai-agents-kit v3 安装器: 把工具包幂等地装到目标项目。
#
# 用法:
#   cd /path/to/your/project
#   bash /path/to/ai-agents-kit/install.sh
#
#   # 非交互模式(适合 CI / 脚本调用):
#   BACKEND_DIR=apps/api FRONTEND_DIR=apps/web \
#     BACKEND_STACK="FastAPI + SQLAlchemy" FRONTEND_STACK="Vite + React" \
#     BACKEND_TEST_CMD="pytest" FRONTEND_TEST_CMD="npm test" \
#     bash /path/to/ai-agents-kit/install.sh --yes
#
#   # 或者直接用 stack 预设 (v3.3.0+):
#   bash /path/to/ai-agents-kit/install.sh --yes --stack python-light       # 默认
#   bash /path/to/ai-agents-kit/install.sh --yes --stack java-enterprise    # 重型 Java
#
#   # 从 v1 迁移(已经按旧版 docs/superpowers/ 装好的项目):
#   bash /path/to/ai-agents-kit/install.sh --migrate-v1
#
# 设计原则(幂等):
# - .claude/settings.json: 已存在用 jq 合并 Stop hook 和 permissions.allow,不覆盖
# - CLAUDE.md: 已存在追加章节(用 marker 定位,可重复升级);自动识别 v1 marker → v2
# - .aiagents/bin/*: 同名直接覆盖(基础设施,不该被手改)
# - .claude/commands/*: 同名先 mv 为 .bak
# - .claude/agents.conf: 已存在保留不覆盖(用户自己的真值)
# - .aiagents/config.json: 用 jq 重新生成(单一真值源)
# - .aiagents/memory/*: 已存在保留不覆盖(用户的记忆资产)
# - .gitignore: 追加 .aiagents/ 相关条目,已存在则跳过

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$KIT_ROOT/templates"
PROJECT_ROOT="$(pwd)"
MARKER_START_V2="<!-- ai-agents-kit:start v2 -->"
MARKER_END_V2="<!-- ai-agents-kit:end v2 -->"
MARKER_START_V1="<!-- ai-agents-kit:start v1 -->"
MARKER_END_V1="<!-- ai-agents-kit:end v1 -->"

AUTO_YES=0
MIGRATE_V1=0
STACK_PRESET=""
WITH_DESIGN_DOC=0
WITH_TEST_CASES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) AUTO_YES=1 ;;
    --migrate-v1) MIGRATE_V1=1 ;;
    --stack) shift; STACK_PRESET="${1:-}" ;;
    --stack=*) STACK_PRESET="${1#--stack=}" ;;
    --with-design-doc) WITH_DESIGN_DOC=1 ;;
    --with-test-cases) WITH_TEST_CASES=1 ;;
    --help|-h)
      cat <<'USAGE'
用法: bash install.sh [--yes] [--stack <preset>] [--with-design-doc] [--with-test-cases] [--migrate-v1]

选项:
  --yes, -y          非交互, 用所有默认值 (空项目默认走 python-light 预设)
  --stack <preset>   指定技术栈预设 (在 --yes 模式下尤其有用):
                       python-light    FastAPI + Vite+React  (默认, 中小项目)
                       python-poetry   FastAPI + Vite+React  (Poetry 包管)
                       java-enterprise Spring Boot + Vite+React (重型企业 Java)
                       java-gradle     Spring Boot Gradle + Vite+React
                       go              Go+Gin + Vite+React
                       node-fullstack  Fastify + Next.js
  --with-design-doc  启用「设计文档」可选阶段: 主 Claude 在 01-需求后产 01.5-设计.md
                     (架构 / 数据模型 / 接口契约 / 状态机 / 关键决策). 默认关闭.
  --with-test-cases  启用「测试用例」可选阶段: 主 Claude 产 01.6-测试用例.md
                     (用例 ID + Given/When/Then + 反向对齐验收点). 默认关闭.
  --migrate-v1       从 v1 旧目录结构迁移
  --help, -h         显示本帮助

示例:
  bash install.sh                                   # 交互式 (会问规模 + 栈 + 命令 + workflow flags)
  bash install.sh --yes                             # 非交互, python-light 默认, workflow 全关
  bash install.sh --yes --stack java-enterprise     # 非交互, 强制 Java
  bash install.sh --yes --with-design-doc           # 非交互, 启用设计文档
  bash install.sh --yes --with-design-doc --with-test-cases   # 两个都开
USAGE
      exit 0 ;;
    *) echo "未知参数: $1 (用 --help 看用法)"; exit 2 ;;
  esac
  shift
done

echo "==========================================="
echo "  ai-agents-kit v3 installer"
echo "  kit   : $KIT_ROOT"
echo "  target: $PROJECT_ROOT"
echo "==========================================="

# ---------- 依赖检测 ----------
missing_deps=()
for cmd in jq bash; do
  command -v "$cmd" >/dev/null 2>&1 || missing_deps+=("$cmd")
done
_python_found=""
for _py in python python3; do
  if command -v "$_py" >/dev/null 2>&1 && "$_py" -c "pass" >/dev/null 2>&1; then
    _python_found="$_py"
    break
  fi
done
if ! command -v jq >/dev/null && [ -z "$_python_found" ]; then
  echo "❌ 需要 jq 或 python (stop-notify.sh / agentctl.sh / agent-runner.sh 用来生成 JSON)"; exit 1
fi
if [ ${#missing_deps[@]} -gt 0 ]; then
  # jq 缺失但有 python → 仅警告(降级);bash 缺失 → 致命
  if [[ " ${missing_deps[*]} " == *" bash "* ]]; then
    echo "❌ 缺少依赖: ${missing_deps[*]}"; exit 1
  else
    echo "⚠️  缺少 jq,部分操作将走 python fallback(较慢)"
  fi
fi

# ---------- v1→v2 兼容检测 ----------
HAS_OLD_LAYOUT=0
[ -d "$PROJECT_ROOT/docs/superpowers/specs" ] && HAS_OLD_LAYOUT=1
HAS_NEW_LAYOUT=0
[ -d "$PROJECT_ROOT/.aiagents/state" ] && HAS_NEW_LAYOUT=1

if [ $MIGRATE_V1 -eq 1 ]; then
  if [ $HAS_OLD_LAYOUT -eq 0 ]; then
    echo "❌ --migrate-v1 但项目里没找到 docs/superpowers/(没有 v1 状态可迁移)"
    exit 1
  fi
  echo "🔄 检测到 v1 布局,准备迁移..."
elif [ $HAS_OLD_LAYOUT -eq 1 ] && [ $HAS_NEW_LAYOUT -eq 0 ]; then
  echo
  echo "⚠️  本项目已经按 ai-agents-kit v1 安装(docs/superpowers/ 存在),但还没有 v2 布局(.aiagents/)。"
  echo "    直接安装会形成混合状态。请改用迁移命令:"
  echo
  echo "      bash $KIT_ROOT/install.sh --migrate-v1"
  echo
  echo "    迁移会保留你的 specs / signals / logs(平移到新位置),并升级 CLAUDE.md 和 settings。"
  exit 2
fi

# ---------- 交互收集配置 ----------
ask() {
  local var="$1" prompt="$2" def="${3:-}"
  local cur="${!var:-$def}"
  if [ $AUTO_YES -eq 1 ]; then
    eval "$var=\$cur"
    echo "  $var = ${cur}"
    return
  fi
  read -r -p "$prompt [$cur]: " input
  if [ -n "$input" ]; then
    eval "$var=\$input"
  else
    eval "$var=\$cur"
  fi
}

# ask_bool VAR "prompt 文本" 0|1   # def=1 表示默认 yes
# --yes 模式下保持现值不问 (CLI flag 已设置过的优先)
ask_bool() {
  local var="$1" prompt="$2" def="${3:-0}"
  local cur="${!var:-$def}"
  if [ $AUTO_YES -eq 1 ]; then
    eval "$var=\$cur"
    echo "  $var = ${cur}"
    return
  fi
  local hint
  if [ "$cur" = 1 ]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "$prompt [$hint]: " input
  case "${input,,}" in
    y|yes|1|true) eval "$var=1" ;;
    n|no|0|false) eval "$var=0" ;;
    "")           eval "$var=\$cur" ;;
    *)            eval "$var=\$cur"; echo "  ⚠️  无法识别 '$input', 保留默认 $cur" ;;
  esac
}

detect_stack() {
  local d="$1"
  if [ ! -d "$d" ] || [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "empty"; return
  fi
  if [ -f "$d/pom.xml" ];                                      then echo "maven-java";    return; fi
  if [ -f "$d/build.gradle" ] || [ -f "$d/build.gradle.kts" ]; then echo "gradle-java";   return; fi
  if [ -f "$d/pyproject.toml" ];                               then echo "python-poetry"; return; fi
  if [ -f "$d/requirements.txt" ];                             then echo "python-pip";    return; fi
  if [ -f "$d/go.mod" ];                                       then echo "go";            return; fi
  if [ -f "$d/Cargo.toml" ];                                   then echo "rust";          return; fi
  if [ -f "$d/package.json" ]; then
    if grep -Eq '"(next|nuxt|vite|react|vue|svelte)"' "$d/package.json" 2>/dev/null; then
      echo "node-frontend"
    else
      echo "node-backend"
    fi
    return
  fi
  echo "unknown"
}

apply_preset() {
  local tag="$1" side="$2" stack test_cmd lint_cmd
  case "$tag" in
    maven-java)    stack="Spring Boot 3 + JPA";           test_cmd="./mvnw test";       lint_cmd="./mvnw spotless:check" ;;
    gradle-java)   stack="Spring Boot 3 (Gradle)";        test_cmd="./gradlew test";    lint_cmd="./gradlew spotlessCheck" ;;
    python-poetry) stack="FastAPI + SQLAlchemy (Poetry)"; test_cmd="poetry run pytest"; lint_cmd="poetry run ruff check" ;;
    python-pip)    stack="FastAPI + SQLAlchemy";          test_cmd="pytest";            lint_cmd="ruff check ." ;;
    go)            stack="Go + Gin";                      test_cmd="go test ./...";     lint_cmd="golangci-lint run" ;;
    rust)          stack="Rust + Axum";                   test_cmd="cargo test";        lint_cmd="cargo clippy -- -D warnings" ;;
    node-backend)  stack="Node.js + Fastify";             test_cmd="npm test";          lint_cmd="npm run lint" ;;
    node-frontend) stack="Vite + React";                  test_cmd="npm test";          lint_cmd="npm run lint" ;;
    nextjs)        stack="Next.js (React)";               test_cmd="npm test";          lint_cmd="npm run lint" ;;
    *) return ;;
  esac
  if [ "$side" = backend ]; then
    BACKEND_STACK="$stack";  BACKEND_TEST_CMD="$test_cmd";  BACKEND_LINT_CMD="$lint_cmd"
  else
    FRONTEND_STACK="$stack"; FRONTEND_TEST_CMD="$test_cmd"; FRONTEND_LINT_CMD="$lint_cmd"
  fi
  echo "  🔍 ${side}: 识别到 ${tag} → ${stack}"
}

# apply_stack_preset <preset-name>
# 把命名预设(--stack flag 接受的名字)展开成两次 apply_preset 调用
# 默认 python-light = FastAPI + Vite+React (中小项目首选, 对齐 choseStock 实战栈)
apply_stack_preset() {
  case "$1" in
    python|python-light|python-pip)
      apply_preset python-pip    backend; apply_preset node-frontend frontend ;;
    python-poetry)
      apply_preset python-poetry backend; apply_preset node-frontend frontend ;;
    java|java-enterprise|java-maven)
      apply_preset maven-java    backend; apply_preset node-frontend frontend ;;
    java-gradle)
      apply_preset gradle-java   backend; apply_preset node-frontend frontend ;;
    go)
      apply_preset go            backend; apply_preset node-frontend frontend ;;
    node|node-fullstack|fullstack-node)
      apply_preset node-backend  backend; apply_preset nextjs        frontend ;;
    "") return 1 ;;  # 空字符串调用方应跳过
    *)
      echo "  ⚠️  未知 --stack=$1, 支持: python-light|python-poetry|java-enterprise|java-gradle|go|node-fullstack" >&2
      return 1 ;;
  esac
}

choose_preset() {
  if [ $AUTO_YES -eq 1 ]; then return; fi
  echo
  echo "📦 未检测到代码 — 选一个起手栈 (后续仍可改 .aiagents/config.json):"
  echo
  echo "  ── 中小项目 / 个人项目 / 内部工具 (推荐轻量栈):"
  echo "    1) Python FastAPI + Vite+React              [默认]  对齐 choseStock 实战栈"
  echo "    2) Python FastAPI (Poetry) + Vite+React              用 poetry 管包"
  echo "  ── 中型企业 / 团队协作:"
  echo "    3) Go (Gin) + Vite+React                             高性能轻量"
  echo "    4) Node.js (Fastify) + Next.js                       全栈 JS"
  echo "  ── 重型企业 / 大型系统:"
  echo "    5) Java (Spring Boot 3 / Maven) + Vite+React         传统重型 Java"
  echo "    6) Java (Spring Boot 3 / Gradle) + Vite+React"
  echo
  echo "    9) 跳过 — 后续手动 ask 每一项"
  local c; read -r -p "选择 [1]: " c; c="${c:-1}"
  case "$c" in
    1) apply_stack_preset python-light    ;;
    2) apply_stack_preset python-poetry   ;;
    3) apply_stack_preset go              ;;
    4) apply_stack_preset node-fullstack  ;;
    5) apply_stack_preset java-enterprise ;;
    6) apply_stack_preset java-gradle     ;;
    *) echo "  跳过预设" ;;
  esac
}

# v3.4.5: --yes 重装存量项目时, 默认目录优先读已有 config.json 的 agents.<a>.dir
# (否则 --yes 用硬默认 backend/frontend, 与项目实际 stock-be/stock-fe 不符 → 子 CLAUDE.md 跳过)
# 注意: config.json 路径必须作为独立 argv 参数传给 python — 嵌在 -c 代码字符串里
# MSYS 不会把 /d/dev/... 转成 Windows 路径, Windows python open() 会失败。
_existing_be_dir="backend"
_existing_fe_dir="frontend"
if [ -f "$PROJECT_ROOT/.aiagents/config.json" ] && [ -n "$_python_found" ]; then
  _cfg_dirs="$("$_python_found" -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    ag = d.get('agents', {}) or {}
    be = (ag.get('backend', {}) or {}).get('dir', '') or (d.get('backend', {}) or {}).get('dir', '')
    fe = (ag.get('frontend', {}) or {}).get('dir', '') or (d.get('frontend', {}) or {}).get('dir', '')
    print(be)
    print(fe)
except Exception:
    print('')
    print('')
" "$PROJECT_ROOT/.aiagents/config.json" 2>/dev/null)"
  _cfg_be="$(printf '%s\n' "$_cfg_dirs" | sed -n '1p')"
  _cfg_fe="$(printf '%s\n' "$_cfg_dirs" | sed -n '2p')"
  [ -n "$_cfg_be" ] && _existing_be_dir="$_cfg_be"
  [ -n "$_cfg_fe" ] && _existing_fe_dir="$_cfg_fe"
fi
ask BACKEND_DIR       "后端目录(相对项目根)"    "$_existing_be_dir"
ask FRONTEND_DIR      "前端目录(相对项目根)"    "$_existing_fe_dir"

echo
echo "🔎 识别技术栈..."
BE_TAG=$(detect_stack "$PROJECT_ROOT/$BACKEND_DIR")
FE_TAG=$(detect_stack "$PROJECT_ROOT/$FRONTEND_DIR")
echo "  backend=$BACKEND_DIR → $BE_TAG"
echo "  frontend=$FRONTEND_DIR → $FE_TAG"

if [ -z "${BACKEND_STACK:-}" ]  && [ "$BE_TAG" != empty ] && [ "$BE_TAG" != unknown ]; then apply_preset "$BE_TAG" backend;  fi
if [ -z "${FRONTEND_STACK:-}" ] && [ "$FE_TAG" != empty ] && [ "$FE_TAG" != unknown ]; then apply_preset "$FE_TAG" frontend; fi

# 优先级: --stack flag > env vars > 工作目录探测 > choose_preset 交互 > --yes 模式空目录走 python-light 兜底
if [ -n "$STACK_PRESET" ] && [ -z "${BACKEND_STACK:-}" ] && [ -z "${FRONTEND_STACK:-}" ]; then
  echo "  🎯 应用 --stack=$STACK_PRESET"
  apply_stack_preset "$STACK_PRESET" || true
fi

if [ -z "${BACKEND_STACK:-}" ] && [ -z "${FRONTEND_STACK:-}" ]; then
  if [ $AUTO_YES -eq 1 ]; then
    # --yes 空目录: 默认走轻量预设 (Lane 偏好: 中小项目用 python, 不要重型 Spring)
    echo "  🌱 --yes 模式空目录: 应用默认 python-light (FastAPI + Vite+React)"
    echo "     如需其他栈请用 --stack <preset>, 见 --help"
    apply_stack_preset python-light
  else
    choose_preset
  fi
fi

# ask 兜底默认值: 也改成 FastAPI 系 (即使 STACK_PRESET 失败 / preset 没覆盖某项, 兜底也是轻量)
ask BACKEND_STACK     "后端技术栈"              "FastAPI + SQLAlchemy"
ask FRONTEND_STACK    "前端技术栈"              "Vite + React"
ask BACKEND_TEST_CMD  "后端测试命令"            "pytest"
ask FRONTEND_TEST_CMD "前端测试命令"            "npm test"
ask BACKEND_LINT_CMD  "后端 lint 命令"          "ruff check ."
ask FRONTEND_LINT_CMD "前端 lint 命令"          "npm run lint"
ask API_CONTRACT_PATH "现有 API 契约路径(可空)" ""

# ---------- 可选阶段产物 (workflow flags) ----------
# 设计文档 / 测试用例不是所有项目都需要, 默认全关. CLI flag (--with-design-doc /
# --with-test-cases) 已置 1 时, 交互模式直接确认; 否则默认 N.
echo
echo "📐 可选阶段产物 (复杂项目推荐启用, 简单项目可跳过):"
ask_bool WITH_DESIGN_DOC  "  启用「设计文档」阶段 (产 01.5-设计.md: 架构 / 数据模型 / 接口契约)" "$WITH_DESIGN_DOC"
ask_bool WITH_TEST_CASES  "  启用「测试用例」阶段 (产 01.6-测试用例.md: Given/When/Then 用例表)" "$WITH_TEST_CASES"

CODEX_BIN_DEFAULT="${CODEX_BIN:-codex}"
# Codex 默认 args: --full-auto 会触 Windows sandbox 卡死(PowerShell command 失败,memory bugs.md
# 多次记录),用 --sandbox danger-full-access --skip-git-repo-check 让 codex 全访问宿主 +
# 不要求工作目录是 git repo(.aiagents/runtime 之类非 git 子目录不会报错)。
CODEX_ARGS_DEFAULT="${CODEX_ARGS:---sandbox danger-full-access --skip-git-repo-check}"
CODEX_TIMEOUT_DEFAULT="${CODEX_TIMEOUT:-1800}"

# ---------- 1. 创建目录骨架(v3 布局) ----------
echo
echo "📁 创建目录骨架(v3)..."
mkdir -p \
  "$PROJECT_ROOT/.claude/commands" \
  "$PROJECT_ROOT/.claude/hooks" \
  "$PROJECT_ROOT/.aiagents/bin" \
  "$PROJECT_ROOT/.aiagents/bin/providers" \
  "$PROJECT_ROOT/.aiagents/signals" \
  "$PROJECT_ROOT/.aiagents/logs" \
  "$PROJECT_ROOT/.aiagents/state" \
  "$PROJECT_ROOT/.aiagents/runtime/heartbeats" \
  "$PROJECT_ROOT/.aiagents/runtime/archive" \
  "$PROJECT_ROOT/.aiagents/prompts" \
  "$PROJECT_ROOT/.aiagents/memory/global" \
  "$PROJECT_ROOT/.aiagents/memory/projects" \
  "$PROJECT_ROOT/.aiagents/memory/ideas" \
  "$PROJECT_ROOT/docs/ai-agents/specs" \
  "$PROJECT_ROOT/docs/ai-agents/reviews" \
  "$PROJECT_ROOT/docs/ai-agents/retrospectives"

# ---------- 2. 复制 .aiagents/bin 脚本 ----------
echo "📜 安装 .aiagents/bin 脚本..."
for f in "$TEMPLATES/.aiagents/bin/"*; do
  [ -f "$f" ] || continue
  fname="$(basename "$f")"
  cp -f "$f" "$PROJECT_ROOT/.aiagents/bin/$fname"
  case "$fname" in
    *.sh) chmod +x "$PROJECT_ROOT/.aiagents/bin/$fname" ;;
  esac
done

# providers/ subdir (v3 multi-provider)
if [ -d "$TEMPLATES/.aiagents/bin/providers" ]; then
  mkdir -p "$PROJECT_ROOT/.aiagents/bin/providers"
  for f in "$TEMPLATES/.aiagents/bin/providers/"*; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    cp -f "$f" "$PROJECT_ROOT/.aiagents/bin/providers/$fname"
    case "$fname" in
      *.sh) chmod +x "$PROJECT_ROOT/.aiagents/bin/providers/$fname" ;;
    esac
  done
  echo "  已安装 .aiagents/bin/providers/ ($(ls -1 "$PROJECT_ROOT/.aiagents/bin/providers/" | wc -l) 个 adapter)"
fi

# ---------- 2.5. 复制 .aiagents/prompts/(v3 cross-provider preamble) ----------
if [ -d "$TEMPLATES/.aiagents/prompts" ]; then
  mkdir -p "$PROJECT_ROOT/.aiagents/prompts"
  for f in "$TEMPLATES/.aiagents/prompts/"*.md; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    cp -f "$f" "$PROJECT_ROOT/.aiagents/prompts/$fname"
  done
  echo "  已安装 .aiagents/prompts/dispatch-preamble.md"
fi

# ---------- 3. 复制 memory 模板(已存在不覆盖) ----------
echo "🧠 安装 memory 模板(保留已有内容)..."
for f in "$TEMPLATES/.aiagents/memory/global/"*.md \
         "$TEMPLATES/.aiagents/memory/projects/"*.md \
         "$TEMPLATES/.aiagents/memory/ideas/"*.md; do
  [ -f "$f" ] || continue
  rel="${f#$TEMPLATES/.aiagents/}"
  tgt="$PROJECT_ROOT/.aiagents/$rel"
  if [ ! -f "$tgt" ]; then
    mkdir -p "$(dirname "$tgt")"
    cp "$f" "$tgt"
  fi
done

# ---------- 4. slash commands(同名先备份) ----------
echo "⚡ 安装 slash commands..."
for f in "$TEMPLATES/.claude/commands/"*.md; do
  fname="$(basename "$f")"
  tgt="$PROJECT_ROOT/.claude/commands/$fname"
  if [ -f "$tgt" ]; then
    if ! diff -q "$f" "$tgt" >/dev/null 2>&1; then
      bak="$tgt.bak.$(date +%s)"
      mv "$tgt" "$bak"
      echo "  已备份现有 $fname → $(basename "$bak")"
    else
      continue
    fi
  fi
  cp "$f" "$tgt"
done

# 清理 v1 遗留的 hook(stop-notify.sh 现在在 .aiagents/bin/)
if [ -f "$PROJECT_ROOT/.claude/hooks/stop-notify.sh" ] || [ -f "$PROJECT_ROOT/.claude/hooks/dispatch.sh" ] || [ -f "$PROJECT_ROOT/.claude/hooks/status.sh" ]; then
  echo "🗑️  备份 v1 遗留的 .claude/hooks/ 脚本..."
  bak_hooks="$PROJECT_ROOT/.claude/hooks.v1.bak.$(date +%s)"
  mv "$PROJECT_ROOT/.claude/hooks" "$bak_hooks"
  mkdir -p "$PROJECT_ROOT/.claude/hooks"
  echo "  → $bak_hooks(可手动删除)"
fi

# ---------- 5. agents.conf(已存在保留) — 向后兼容 ----------
CONF="$PROJECT_ROOT/.claude/agents.conf"
if [ -f "$CONF" ]; then
  echo "🔧 .claude/agents.conf 已存在,保留不覆盖。"
else
  echo "🔧 生成 .claude/agents.conf(向后兼容,KV 格式)..."
  cat > "$CONF" <<EOF
# 多Agent协作工作流 — 项目级配置(被 hook 脚本 source,向后兼容 v1)
# v2 起 .aiagents/config.json 是 single source of truth,本文件仅做 fallback。
BACKEND_DIR="$BACKEND_DIR"
FRONTEND_DIR="$FRONTEND_DIR"
BACKEND_TEST_CMD="$BACKEND_TEST_CMD"
FRONTEND_TEST_CMD="$FRONTEND_TEST_CMD"
BACKEND_LINT_CMD="$BACKEND_LINT_CMD"
FRONTEND_LINT_CMD="$FRONTEND_LINT_CMD"
BACKEND_STACK="$BACKEND_STACK"
FRONTEND_STACK="$FRONTEND_STACK"
CODEX_BIN="$CODEX_BIN_DEFAULT"
CODEX_ARGS="$CODEX_ARGS_DEFAULT"
MAX_RETRY=3
CODEX_TIMEOUT=$CODEX_TIMEOUT_DEFAULT
EOF
fi

# ---------- 6. 生成 .aiagents/config.json(v3 JSON 真值源) ----------
CFG_JSON="$PROJECT_ROOT/.aiagents/config.json"

write_v3_config() {
  local cfg_path="$1"
  "$_python_found" - \
      "$cfg_path" \
      "$BACKEND_DIR" "$FRONTEND_DIR" \
      "$BACKEND_STACK" "$FRONTEND_STACK" \
      "$BACKEND_TEST_CMD" "$FRONTEND_TEST_CMD" \
      "$BACKEND_LINT_CMD" "$FRONTEND_LINT_CMD" \
      "$CODEX_BIN_DEFAULT" "$CODEX_ARGS_DEFAULT" "$CODEX_TIMEOUT_DEFAULT" \
      "$WITH_DESIGN_DOC" "$WITH_TEST_CASES" <<'PY'
import json, os, sys
path, bd, fd, bs, fs, btc, ftc, blc, flc, cb, ca, cto, wdd, wtc = sys.argv[1:15]
with_design = wdd == "1"
with_tests  = wtc == "1"

# Detect existing config
existing = None
if os.path.exists(path):
    try:
        existing = json.load(open(path, encoding="utf-8"))
    except Exception:
        existing = None

# v3 already -> 保留全部既有定制, 但仍要保证 workflow flags / notify 块存在 (idempotent 补齐)
if existing and existing.get("providers"):
    wf = existing.setdefault("workflow", {})
    needs_save = False
    if "design_doc" not in wf:
        wf["design_doc"] = {"enabled": False, "spec_file": "docs/ai-agents/specs/01.5-设计.md"}
        needs_save = True
    if "test_cases" not in wf:
        wf["test_cases"] = {"enabled": False, "spec_file": "docs/ai-agents/specs/01.6-测试用例.md"}
        needs_save = True
    if with_design and not wf["design_doc"]["enabled"]:
        wf["design_doc"]["enabled"] = True
        needs_save = True
    if with_tests and not wf["test_cases"]["enabled"]:
        wf["test_cases"]["enabled"] = True
        needs_save = True
    # v3.6: notify.push 块 (移动端推送, 默认关 — provider 留空)
    nt = existing.setdefault("notify", {})
    if "push" not in nt:
        nt["push"] = {"provider": "", "key": "", "url": "", "events": ["done", "failed", "timeout", "stale"]}
        needs_save = True
    if needs_save:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(existing, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"[install] v3 config preserved; workflow/notify updated (design_doc.enabled={wf['design_doc']['enabled']}, test_cases.enabled={wf['test_cases']['enabled']})", file=sys.stderr)
    else:
        print("[install] config.json is already v3 -- skipping rewrite", file=sys.stderr)
    sys.exit(0)

# v2 detected -> migrate
if existing and existing.get("codex"):
    print("[install] detected v2 config.json -- auto-migrating codex.* -> providers.codex.*", file=sys.stderr)
    new_cfg = {
        "version": "3.0.0",
        "namespace": "ai-agents-kit",
        "default_provider": "codex",
        "agents": {
            "backend":  {
                "dir":   existing.get("backend", {}).get("dir", bd),
                "stack": existing.get("backend", {}).get("stack", bs),
                "provider": "codex",
                "test_cmd": existing.get("backend", {}).get("test_cmd", btc),
                "lint_cmd": existing.get("backend", {}).get("lint_cmd", blc),
            },
            "frontend": {
                "dir":   existing.get("frontend", {}).get("dir", fd),
                "stack": existing.get("frontend", {}).get("stack", fs),
                "provider": "codex",
                "test_cmd": existing.get("frontend", {}).get("test_cmd", ftc),
                "lint_cmd": existing.get("frontend", {}).get("lint_cmd", flc),
            },
        },
        "providers": {
            "codex":  {
                "bin":  existing.get("codex", {}).get("bin", cb),
                "args": existing.get("codex", {}).get("args", ca),
                "timeout": int(existing.get("codex", {}).get("timeout_seconds", cto)),
                "subcommand": "exec",
                "stdin_supported": True,
            },
            "claude": {
                "bin": "claude",
                "args": "--dangerously-skip-permissions",
                "timeout": 2400,
                "subcommand": "-p",
                "stdin_supported": True,
            },
        },
        "workflow": existing.get("workflow", {"max_retry": 3, "require_review_before_frontend": True, "human_override_after_retry": 3}),
        "paths": existing.get("paths", {}),
    }
else:
    # Fresh
    print("[install] fresh v3 config.json", file=sys.stderr)
    new_cfg = {
        "version": "3.0.0",
        "namespace": "ai-agents-kit",
        "default_provider": "codex",
        "agents": {
            "backend":  {"dir": bd, "stack": bs, "provider": "codex", "test_cmd": btc, "lint_cmd": blc},
            "frontend": {"dir": fd, "stack": fs, "provider": "codex", "test_cmd": ftc, "lint_cmd": flc},
        },
        "providers": {
            # model 字段为空时让 CLI 走默认; Lane 可改 "sonnet" / "haiku" / 完整模型名做 per-provider 默认
            "codex":  {"bin": cb, "args": ca, "model": "", "timeout": int(cto), "subcommand": "exec", "stdin_supported": True},
            "claude": {"bin": "claude", "args": "--dangerously-skip-permissions", "model": "", "timeout": 2400, "subcommand": "-p", "stdin_supported": True},
        },
        "workflow": {"max_retry": 3, "require_review_before_frontend": True, "human_override_after_retry": 3},
        "paths": {},
    }

# Optional stage outputs (idempotent: 已有项目重跑也能加上)
new_cfg.setdefault("workflow", {})
wf = new_cfg["workflow"]
wf.setdefault("design_doc",  {"enabled": False, "spec_file": "docs/ai-agents/specs/01.5-设计.md"})
wf.setdefault("test_cases",  {"enabled": False, "spec_file": "docs/ai-agents/specs/01.6-测试用例.md"})
# CLI / 交互显式设置过则覆盖 (空项目首装 + 已装项目重跑加 flag 都生效)
if with_design:
    wf["design_doc"]["enabled"] = True
if with_tests:
    wf["test_cases"]["enabled"] = True

# v3.6: notify.push 块 (移动端推送, 默认关 — Lane 填 provider/key 后启用)
new_cfg.setdefault("notify", {}).setdefault(
    "push", {"provider": "", "key": "", "url": "", "events": ["done", "failed", "timeout", "stale"]})

# Ensure paths defaults (always set; existing may have partial)
default_paths = {
    "specs": "docs/ai-agents/specs",
    "reviews": "docs/ai-agents/reviews",
    "retrospectives": "docs/ai-agents/retrospectives",
    "signals": ".aiagents/signals",
    "logs": ".aiagents/logs",
    "state": ".aiagents/state",
    "memory": ".aiagents/memory",
    "prompts": ".aiagents/prompts",
    "runtime": ".aiagents/runtime",
}
for k, v in default_paths.items():
    new_cfg["paths"].setdefault(k, v)

with open(path, "w", encoding="utf-8") as f:
    json.dump(new_cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

echo "🧩 生成 .aiagents/config.json (v3 schema)..."
if [ -n "$_python_found" ]; then
  write_v3_config "$CFG_JSON"
elif command -v jq >/dev/null 2>&1; then
  # jq-only fallback: always writes fresh v3 (no migration support without python)
  # 注: jq fallback 不支持已装项目的 in-place workflow flag 更新 (那条路径需要 python).
  # 若已装项目重跑 install 且没装 python -- 已有 config.json 不动, flag 修改请手动编辑.
  if [ -f "$CFG_JSON" ]; then
    echo "  ⚠️  config.json 已存在 + 当前是 jq fallback (无 python), 跳过 rewrite. 改 workflow 请手编辑."
  else
    _design_enabled=false; _tests_enabled=false
    [ "$WITH_DESIGN_DOC" = 1 ] && _design_enabled=true
    [ "$WITH_TEST_CASES" = 1 ] && _tests_enabled=true
    jq -n \
      --arg bd  "$BACKEND_DIR"          --arg fd  "$FRONTEND_DIR" \
      --arg bs  "$BACKEND_STACK"        --arg fs  "$FRONTEND_STACK" \
      --arg btc "$BACKEND_TEST_CMD"     --arg ftc "$FRONTEND_TEST_CMD" \
      --arg blc "$BACKEND_LINT_CMD"     --arg flc "$FRONTEND_LINT_CMD" \
      --arg cb  "$CODEX_BIN_DEFAULT"    --arg ca  "$CODEX_ARGS_DEFAULT" \
      --argjson cto "$CODEX_TIMEOUT_DEFAULT" \
      --argjson design "$_design_enabled" \
      --argjson tests  "$_tests_enabled" \
      '{
         version: "3.0.0",
         namespace: "ai-agents-kit",
         default_provider: "codex",
         agents: {
           backend:  {dir: $bd, stack: $bs, provider: "codex", test_cmd: $btc, lint_cmd: $blc},
           frontend: {dir: $fd, stack: $fs, provider: "codex", test_cmd: $ftc, lint_cmd: $flc}
         },
         providers: {
           codex:  {bin: $cb, args: $ca, model: "", timeout: $cto, subcommand: "exec", stdin_supported: true},
           claude: {bin: "claude", args: "--dangerously-skip-permissions", model: "", timeout: 2400, subcommand: "-p", stdin_supported: true}
         },
         workflow: {
           max_retry: 3,
           require_review_before_frontend: true,
           human_override_after_retry: 3,
           design_doc: {enabled: $design, spec_file: "docs/ai-agents/specs/01.5-设计.md"},
           test_cases: {enabled: $tests,  spec_file: "docs/ai-agents/specs/01.6-测试用例.md"}
         },
         notify: {
           push: {provider: "", key: "", url: "", events: ["done","failed","timeout","stale"]}
         },
         paths: {
           specs: "docs/ai-agents/specs",
           reviews: "docs/ai-agents/reviews",
           retrospectives: "docs/ai-agents/retrospectives",
           signals: ".aiagents/signals",
           logs: ".aiagents/logs",
           state: ".aiagents/state",
           memory: ".aiagents/memory",
           prompts: ".aiagents/prompts",
           runtime: ".aiagents/runtime"
         }
       }' > "$CFG_JSON"
  fi
else
  echo "❌ 需要 python 或 jq 生成 config.json"; exit 1
fi

# ---------- 7. settings.json(jq 幂等合并 + placeholder 替换) ----------
SETTINGS="$PROJECT_ROOT/.claude/settings.json"
TEMPLATE_SETTINGS="$TEMPLATES/.claude/settings.json"
echo "🧩 合并 .claude/settings.json..."

# Render template with real dir values (substitutes ${BACKEND_DIR} / ${FRONTEND_DIR} placeholders)
TEMPLATE_SETTINGS_RENDERED="$(mktemp)"
sed -e "s|\${BACKEND_DIR}|$BACKEND_DIR|g" \
    -e "s|\${FRONTEND_DIR}|$FRONTEND_DIR|g" \
    "$TEMPLATE_SETTINGS" > "$TEMPLATE_SETTINGS_RENDERED"

if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq -s '
    .[0] as $existing | .[1] as $kit |
    $existing
    | (.hooks //= {})
    | (.hooks.Stop //= [])
    # 移除 v1 stop-notify.sh 的旧 Stop hook,然后追加 v2/v3 的(避免重复)
    | .hooks.Stop |= [.[] | select(.hooks[0].command | contains(".claude/hooks/stop-notify.sh") | not)]
    | .hooks.Stop |= (. + ($kit.hooks.Stop // []) | unique_by(.hooks[0].command))
    | (.permissions //= {})
    | (.permissions.allow //= [])
    | .permissions.allow |= (. + ($kit.permissions.allow // []) | unique)
    | (.permissions.deny //= [])
    | .permissions.deny |= (. + ($kit.permissions.deny // []) | unique)
  ' "$SETTINGS" "$TEMPLATE_SETTINGS_RENDERED" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "  已合并 Stop hook、permissions.allow 与 permissions.deny(并清理 v1 hook)"
elif [ -f "$SETTINGS" ]; then
  echo "  ⚠️  jq 不可用,settings.json 已存在 — 请手动检查 hooks.Stop 是否指向 .aiagents/bin/stop-notify.sh"
else
  cp "$TEMPLATE_SETTINGS_RENDERED" "$SETTINGS"
  echo "  新建(含 deny 规则替换)"
fi
rm -f "$TEMPLATE_SETTINGS_RENDERED"

# ---------- 8. CLAUDE.md(v1→v2 自动升级) ----------
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
TEMPLATE_CLAUDE="$TEMPLATES/CLAUDE.md"
echo "📝 同步 CLAUDE.md 多Agent 章节..."
rendered_full="$(sed \
  -e "s|<BACKEND_STACK>|$BACKEND_STACK|g" \
  -e "s|<FRONTEND_STACK>|$FRONTEND_STACK|g" \
  -e "s|<BACKEND_TEST_CMD>|$BACKEND_TEST_CMD|g" \
  -e "s|<FRONTEND_TEST_CMD>|$FRONTEND_TEST_CMD|g" \
  -e "s|<BACKEND_LINT_CMD>|$BACKEND_LINT_CMD|g" \
  -e "s|<FRONTEND_LINT_CMD>|$FRONTEND_LINT_CMD|g" \
  -e "s|<API_CONTRACT_PATH>|${API_CONTRACT_PATH:-(无)}|g" \
  "$TEMPLATE_CLAUDE")"
# Bug 修复 (重复标题): 旧版 rendered 含 marker 之前的标题块, replace_block 在 marker 处
# 插入整个 rendered, 而原 CLAUDE.md 的标题(marker 外)保留 → 每跑一次 install 多一个标题块。
# 修复: 拆成两部分 —— CLAUDE_HEADER (marker 前的标题) + rendered (marker 起的正文)。
# replace_block 只用 rendered (无标题), 标题永远是原文件那一份, 不再重复。
CLAUDE_HEADER="$(printf '%s\n' "$rendered_full" | sed '/ai-agents-kit:start v2/,$d')"
rendered="$(printf '%s\n' "$rendered_full" | sed -n '/ai-agents-kit:start v2/,$p')"

replace_block() {
  local file="$1" start="$2" end="$3" block="$4"
  awk -v start="$start" -v end="$end" -v block="$block" '
    BEGIN{in_block=0; printed=0}
    {
      if (index($0, start) > 0) { in_block=1; if (!printed) { print block; printed=1 }; next }
      if (index($0, end)   > 0) { in_block=0; next }
      if (!in_block) print
    }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

if [ -f "$CLAUDE_MD" ]; then
  if grep -q "$MARKER_START_V2" "$CLAUDE_MD"; then
    replace_block "$CLAUDE_MD" "$MARKER_START_V2" "$MARKER_END_V2" "$rendered"
    echo "  已就地升级 v2 章节"
  elif grep -q "$MARKER_START_V1" "$CLAUDE_MD"; then
    bak="$CLAUDE_MD.v1.bak.$(date +%s)"
    cp "$CLAUDE_MD" "$bak"
    echo "  备份 v1 版本到 $(basename "$bak")"
    replace_block "$CLAUDE_MD" "$MARKER_START_V1" "$MARKER_END_V1" "$rendered"
    echo "  已把 v1 章节升级为 v2"
  else
    printf '\n\n' >> "$CLAUDE_MD"
    echo "$CLAUDE_HEADER" >> "$CLAUDE_MD"
    echo "$rendered" >> "$CLAUDE_MD"
    echo "  已追加 v2 章节到已有 CLAUDE.md"
  fi
else
  { echo "$CLAUDE_HEADER"; echo "$rendered"; } > "$CLAUDE_MD"
  echo "  已新建 CLAUDE.md"
fi

# ---------- 8.5. backend/frontend 编码 agent CLAUDE.md ----------
deploy_agent_claude() {
  local agent="$1" agent_dir="$2"
  local src="$TEMPLATES/${agent}-CLAUDE.md"
  [ -f "$src" ] || return 0
  [ -n "$agent_dir" ] || return 0
  # Resolve to absolute path under project root
  local abs_dir
  case "$agent_dir" in
    /*|[A-Za-z]:*) abs_dir="$agent_dir" ;;
    *) abs_dir="$PROJECT_ROOT/$agent_dir" ;;
  esac
  [ -d "$abs_dir" ] || { echo "  ⚠️  ${agent} 工作目录不存在: $abs_dir,跳过 CLAUDE.md 部署"; return 0; }
  local target="$abs_dir/CLAUDE.md"
  # Substitute placeholders
  local rendered
  rendered="$(sed \
    -e "s|\${BACKEND_DIR}|$BACKEND_DIR|g" \
    -e "s|\${FRONTEND_DIR}|$FRONTEND_DIR|g" \
    "$src")"
  if [ -f "$target" ]; then
    if grep -q "ai-agents-kit:agent-claude-md" "$target" 2>/dev/null; then
      # Already managed by kit; rewrite
      echo "$rendered" > "$target"
      echo "  已更新 $target (kit-managed)"
    else
      # User has own CLAUDE.md -- don't overwrite
      bak="$target.kit-suggest.$(date +%s)"
      echo "$rendered" > "$bak"
      echo "  ⚠️  $target 已存在(非 kit-managed),建议手工合并 → $(basename "$bak")"
    fi
  else
    echo "$rendered" > "$target"
    echo "  已部署 $target"
  fi
}

echo "📝 部署编码 agent 子目录 CLAUDE.md..."
deploy_agent_claude backend "$BACKEND_DIR"
deploy_agent_claude frontend "$FRONTEND_DIR"

# ---------- 9. (已废弃) start-agents.sh tmux 启动器 ----------
# v3.5+ 不再支持 tmux 一屏分屏方式. 推荐统一用 `agentctl.sh up` 后台 + Cursor/VSCode
# 多终端面板. 若旧版安装遗留了 start-agents.sh, 备份重命名(不强删, 防止 Lane 自定义过).
START="$PROJECT_ROOT/start-agents.sh"
if [ -f "$START" ] && grep -q "ai-agents-kit" "$START"; then
  mv "$START" "$START.deprecated.$(date +%s)"
  echo "🗑️  已废弃 tmux 启动方式: start-agents.sh → $(basename "$START").deprecated.*"
  echo "    新启动: bash .aiagents/bin/agentctl.sh up"
fi

# ---------- 10. .gitignore ----------
GI="$PROJECT_ROOT/.gitignore"
touch "$GI"
echo "📦 同步 .gitignore..."
for line in \
  ".aiagents/signals/" \
  ".aiagents/logs/" \
  ".aiagents/state/" \
  ".aiagents/runtime/" \
  "docs/ai-agents/specs/.consumed_*" \
  "docs/superpowers/signals/" \
  "docs/superpowers/logs/" \
  "docs/superpowers/specs/.consumed_*"
do
  if ! grep -Fxq "$line" "$GI"; then
    echo "$line" >> "$GI"
  fi
done

# ---------- 11. 操作手册 ----------
mkdir -p "$PROJECT_ROOT/docs/ai-agents"
cp -f "$TEMPLATES/docs/ai-agents/README.md" "$PROJECT_ROOT/docs/ai-agents/README.md" 2>/dev/null || true

# ---------- 12. v1 → v2 迁移(--migrate-v1) ----------
if [ $MIGRATE_V1 -eq 1 ]; then
  echo
  echo "🚚 v1 → v2 数据迁移..."
  OLD="$PROJECT_ROOT/docs/superpowers"

  # specs
  if [ -d "$OLD/specs" ]; then
    for f in "$OLD/specs/"*; do
      [ -e "$f" ] || continue
      tgt="$PROJECT_ROOT/docs/ai-agents/specs/$(basename "$f")"
      if [ ! -e "$tgt" ]; then
        mv "$f" "$tgt"
        echo "  specs: $(basename "$f")"
      fi
    done
  fi

  # signals(包括 .consumed_*)
  if [ -d "$OLD/signals" ]; then
    for f in "$OLD/signals/"*; do
      [ -e "$f" ] || continue
      tgt="$PROJECT_ROOT/.aiagents/signals/$(basename "$f")"
      if [ ! -e "$tgt" ]; then
        mv "$f" "$tgt" 2>/dev/null || true
      fi
    done
  fi

  # logs
  if [ -d "$OLD/logs" ]; then
    for f in "$OLD/logs/"*; do
      [ -e "$f" ] || continue
      tgt="$PROJECT_ROOT/.aiagents/logs/$(basename "$f")"
      if [ ! -e "$tgt" ]; then
        mv "$f" "$tgt"
      fi
    done
  fi

  # 旧 bin 不再使用,直接备份移除
  if [ -d "$OLD/bin" ]; then
    bak="$OLD/bin.v1.bak.$(date +%s)"
    mv "$OLD/bin" "$bak"
    echo "  备份旧 bin/ → $(basename "$bak")"
  fi

  # 留一个 MIGRATED.md 提示
  cat > "$OLD/MIGRATED.md" <<EOF
# v1 → v2 已迁移

本目录(\`docs/superpowers/\`)的内容已经迁移到:
- specs/      → \`docs/ai-agents/specs/\`
- signals/    → \`.aiagents/signals/\`
- logs/       → \`.aiagents/logs/\`
- bin/        → 不再使用(旧脚本备份在同级 \`bin.v1.bak.*\`)

新版执行链:
\`signal → .aiagents/bin/watch-agent.sh → .aiagents/bin/agent-runner.sh → codex → state/event\`

可以安全删除本目录。
EOF
  echo "  迁移完成。已写 $OLD/MIGRATED.md 说明。"
fi

# ---------- 13. STACK ↔ TEST_CMD / LINT_CMD 一致性检查 ----------
warnings=()
check_consistency() {
  local side="$1" stack="$2" test_cmd="$3" lint_cmd="$4"
  local s_lc="${stack,,}"
  local t_lc="${test_cmd,,}"
  local l_lc="${lint_cmd,,}"
  local expected=""

  case "$s_lc" in
    *python*|*fastapi*|*django*|*flask*|*pyhton*|*py3*|*py\ *) expected="python" ;;
    *spring*|*java*|*maven*)             expected="maven" ;;
    *gradle*)                            expected="gradle" ;;
    *next*|*nuxt*|*vite*|*react*|*vue*|*svelte*|*node*|*express*|*fastify*) expected="node" ;;
    *" go"*|"go "*|*golang*|*gin*)       expected="go" ;;
    *rust*|*cargo*|*axum*)               expected="cargo" ;;
    *)
      warnings+=("$side: STACK=\"$stack\" 我没认出来(非英文关键字),无法自动校验 TEST/LINT 一致性,请手动确认 .aiagents/config.json")
      return ;;
  esac

  local actual=""
  case "$t_lc" in
    *pytest*|*poetry*|*python*) actual="python" ;;
    *mvnw*|*maven*|*mvn\ *)     actual="maven" ;;
    *gradlew*|*gradle*)         actual="gradle" ;;
    *npm*|*yarn*|*pnpm*|*node*) actual="node" ;;
    *go\ test*|*go\ vet*)       actual="go" ;;
    *cargo*)                    actual="cargo" ;;
  esac

  if [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
    warnings+=("$side: STACK=\"$stack\" 看起来是 $expected,但 TEST_CMD=\"$test_cmd\" 是 $actual → 不一致")
  fi
  case "$l_lc" in
    *mvnw*|*maven*) [ "$expected" != "maven" ]  && warnings+=("$side LINT_CMD=$lint_cmd 与 $expected 栈不符") ;;
    *gradle*)       [ "$expected" != "gradle" ] && warnings+=("$side LINT_CMD=$lint_cmd 与 $expected 栈不符") ;;
    *ruff*|*flake*|*black*) [ "$expected" != "python" ] && warnings+=("$side LINT_CMD=$lint_cmd 与 $expected 栈不符") ;;
    *eslint*|*npm\ run\ lint*) [ "$expected" != "node" ] && warnings+=("$side LINT_CMD=$lint_cmd 与 $expected 栈不符") ;;
  esac
  return 0   # 显式 0: 否则 case 块最后一个 [ ... ] 测试返回 false 时, 函数 return 1, set -e 杀脚本
}
check_consistency backend  "$BACKEND_STACK"  "$BACKEND_TEST_CMD"  "$BACKEND_LINT_CMD"
check_consistency frontend "$FRONTEND_STACK" "$FRONTEND_TEST_CMD" "$FRONTEND_LINT_CMD"

if [ ${#warnings[@]} -gt 0 ]; then
  echo
  echo "⚠️  一致性警告 — 请确认 .aiagents/config.json 的 TEST/LINT 与 STACK 匹配:"
  for w in "${warnings[@]}"; do echo "    - $w"; done
  echo "    (Claude 的 Goal-Driven Execution 会跑这些命令验收,不一致会盲跑失败)"
fi

# ---------- 14. 完成 ----------
echo
echo "==========================================="
if [ $MIGRATE_V1 -eq 1 ]; then
  echo "✅ v1 → v3 迁移完成"
else
  echo "✅ 安装完成 (v3)"
fi
echo "==========================================="
echo
echo "  推荐启动 (后台 watcher + Cursor/VSCode 多终端面板):"
echo "    面板 1> claude ."
echo "    面板 2> bash .aiagents/bin/agentctl.sh up           # 起后端 + 前端 watcher (一次性)"
echo "    面板 3> bash .aiagents/bin/agentctl.sh logs both    # 监控实时日志 (可选)"
echo
echo "  Windows PowerShell 等价:"
echo "    pwsh .aiagents\\bin\\agentctl.ps1 up"
echo
echo "  常用命令:"
echo "    bash .aiagents/bin/agentctl.sh status"
echo "    bash .aiagents/bin/agentctl.sh dispatch backend"
echo "    bash .aiagents/bin/agentctl.sh memory \"一条经验\""
echo
echo "  手册: $PROJECT_ROOT/docs/ai-agents/README.md"
echo "  配置: $CFG_JSON  +  $CONF (KV 兼容)"
echo
echo "  📐 可选阶段产物 (workflow flags):"
if [ "$WITH_DESIGN_DOC" = 1 ]; then echo "    ✅ 设计文档     → 主 Claude 会产 docs/ai-agents/specs/01.5-设计.md"
                              else echo "    ⬜ 设计文档     (关) — 改 .aiagents/config.json workflow.design_doc.enabled=true 或重跑 install --with-design-doc"; fi
if [ "$WITH_TEST_CASES" = 1 ]; then echo "    ✅ 测试用例     → 主 Claude 会产 docs/ai-agents/specs/01.6-测试用例.md"
                              else echo "    ⬜ 测试用例     (关) — 改 .aiagents/config.json workflow.test_cases.enabled=true 或重跑 install --with-test-cases"; fi
echo

# ---------- v3.1 桌面通知提示 ----------
if [ "$(uname -s 2>/dev/null)" != "Linux" ] && [ "$(uname -s 2>/dev/null | head -c 6)" != "Darwin" ]; then
  echo "  🔔 桌面通知 (v3.1+):"
  if command -v pwsh >/dev/null 2>&1; then
    if pwsh -NoProfile -Command "Get-Module -ListAvailable BurntToast | Select-Object -First 1" 2>/dev/null | grep -q BurntToast; then
      echo "    ✅ BurntToast 已装,任务完成会弹漂亮 Toast"
    else
      echo "    ✅ NotifyIcon 兜底可用 (任务完成会弹系统托盘气泡)"
      echo "    💡 想要更漂亮的 Toast? 一次性安装 BurntToast:"
      echo "       pwsh -Command \"Install-Module BurntToast -Scope CurrentUser -Force\""
    fi
  else
    echo "    ⚠️  pwsh 不可用,通知层关闭 (主流程仍正常,只是 Lane 离线时无提醒)"
  fi
  echo
fi
