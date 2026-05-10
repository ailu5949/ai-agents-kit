#requires -Version 5.1
# ai-agents-kit v2 PowerShell 安装器
# 用法:
#   pwsh C:\Users\mi\ai-agents-kit\install.ps1
#   pwsh C:\Users\mi\ai-agents-kit\install.ps1 -Yes
#   pwsh C:\Users\mi\ai-agents-kit\install.ps1 -MigrateV1
#   pwsh C:\Users\mi\ai-agents-kit\install.ps1 -BackendDir "backend" -FrontendDir "frontend" -Yes

[CmdletBinding()]
param(
  [string]$BackendDir = "",
  [string]$FrontendDir = "",
  [string]$BackendStack = "",
  [string]$FrontendStack = "",
  [string]$BackendTestCmd = "",
  [string]$FrontendTestCmd = "",
  [string]$BackendLintCmd = "",
  [string]$FrontendLintCmd = "",
  [string]$ApiContractPath = "",
  [string]$CodexBin = "codex",
  [string]$CodexArgs = "--full-auto",
  [int]$CodexTimeout = 1800,
  [string]$Stack = "",
  [switch]$Yes,
  [switch]$MigrateV1
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Write-Utf8File([string]$Path, [string]$Content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Copy-TemplateDir([string]$Source, [string]$Target) {
  if (-not (Test-Path $Source)) { return }
  Get-ChildItem -Path $Source -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($Source.Length).TrimStart("\", "/")
    $dest = Join-Path $Target $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -Force -LiteralPath $_.FullName -Destination $dest
  }
}

$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplateRoot = Join-Path $KitRoot "templates"
$ProjectRoot = (Get-Location).Path
$MarkerStartV2 = "<!-- ai-agents-kit:start v2 -->"
$MarkerEndV2 = "<!-- ai-agents-kit:end v2 -->"
$MarkerStartV1 = "<!-- ai-agents-kit:start v1 -->"
$MarkerEndV1 = "<!-- ai-agents-kit:end v1 -->"

Write-Host "==========================================="
Write-Host "  ai-agents-kit v2 PowerShell installer"
Write-Host "  kit   : $KitRoot"
Write-Host "  target: $ProjectRoot"
Write-Host "==========================================="

# ---------- 依赖检测 ----------
$hasJq = $null -ne (Get-Command "jq" -ErrorAction SilentlyContinue)
$pythonBin = $null
foreach ($p in @("python3", "python")) {
  if (Get-Command $p -ErrorAction SilentlyContinue) { $pythonBin = $p; break }
}
if (-not $hasJq -and -not $pythonBin) {
  throw "需要 jq 或 python 之一(脚本运行时用来生成 JSON)"
}

# ---------- v1→v2 兼容检测 ----------
$hasOldLayout = Test-Path (Join-Path $ProjectRoot "docs\superpowers\specs")
$hasNewLayout = Test-Path (Join-Path $ProjectRoot ".aiagents\state")

if ($MigrateV1) {
  if (-not $hasOldLayout) { throw "--MigrateV1 但项目里没找到 docs/superpowers/(没有 v1 状态可迁移)" }
  Write-Host "🔄 检测到 v1 布局,准备迁移..."
} elseif ($hasOldLayout -and -not $hasNewLayout) {
  Write-Host ""
  Write-Host "⚠️  本项目已经按 ai-agents-kit v1 安装,但还没有 v2 布局。"
  Write-Host "    请改用迁移命令:"
  Write-Host "      pwsh $KitRoot\install.ps1 -MigrateV1"
  exit 2
}

# ---------- 交互填值 ----------
function Ask([string]$Prompt, [string]$Current, [string]$Default) {
  $val = if ($Current) { $Current } else { $Default }
  if ($Yes) { Write-Host "  $Prompt = $val"; return $val }
  $input = Read-Host "$Prompt [$val]"
  if ($input) { return $input } else { return $val }
}

function Detect-Stack([string]$Dir) {
  if (-not (Test-Path $Dir)) { return "empty" }
  $items = Get-ChildItem -Path $Dir -ErrorAction SilentlyContinue
  if (-not $items) { return "empty" }
  if (Test-Path (Join-Path $Dir "pom.xml")) { return "maven-java" }
  if ((Test-Path (Join-Path $Dir "build.gradle")) -or (Test-Path (Join-Path $Dir "build.gradle.kts"))) { return "gradle-java" }
  if (Test-Path (Join-Path $Dir "pyproject.toml")) { return "python-poetry" }
  if (Test-Path (Join-Path $Dir "requirements.txt")) { return "python-pip" }
  if (Test-Path (Join-Path $Dir "go.mod")) { return "go" }
  if (Test-Path (Join-Path $Dir "Cargo.toml")) { return "rust" }
  $pkgJson = Join-Path $Dir "package.json"
  if (Test-Path $pkgJson) {
    $content = Get-Content -Raw -Encoding UTF8 $pkgJson
    if ($content -match '"(next|nuxt|vite|react|vue|svelte)"') { return "node-frontend" }
    return "node-backend"
  }
  return "unknown"
}

function Apply-Preset([string]$Tag, [string]$Side) {
  $stack = ""; $testCmd = ""; $lintCmd = ""
  switch ($Tag) {
    "maven-java"    { $stack = "Spring Boot 3 + JPA";           $testCmd = ".\mvnw test";          $lintCmd = ".\mvnw spotless:check" }
    "gradle-java"   { $stack = "Spring Boot 3 (Gradle)";        $testCmd = ".\gradlew test";       $lintCmd = ".\gradlew spotlessCheck" }
    "python-poetry" { $stack = "FastAPI + SQLAlchemy (Poetry)"; $testCmd = "poetry run pytest";    $lintCmd = "poetry run ruff check" }
    "python-pip"    { $stack = "FastAPI + SQLAlchemy";          $testCmd = "pytest";               $lintCmd = "ruff check ." }
    "go"            { $stack = "Go + Gin";                      $testCmd = "go test ./...";        $lintCmd = "golangci-lint run" }
    "rust"          { $stack = "Rust + Axum";                   $testCmd = "cargo test";           $lintCmd = "cargo clippy -- -D warnings" }
    "node-backend"  { $stack = "Node.js + Fastify";             $testCmd = "npm test";             $lintCmd = "npm run lint" }
    "node-frontend" { $stack = "Vite + React";                  $testCmd = "npm test";             $lintCmd = "npm run lint" }
    "nextjs"        { $stack = "Next.js (React)";               $testCmd = "npm test";             $lintCmd = "npm run lint" }
    default { return }
  }
  if ($Side -eq "backend") {
    if (-not $script:BackendStack)    { $script:BackendStack    = $stack }
    if (-not $script:BackendTestCmd)  { $script:BackendTestCmd  = $testCmd }
    if (-not $script:BackendLintCmd)  { $script:BackendLintCmd  = $lintCmd }
  } else {
    if (-not $script:FrontendStack)   { $script:FrontendStack   = $stack }
    if (-not $script:FrontendTestCmd) { $script:FrontendTestCmd = $testCmd }
    if (-not $script:FrontendLintCmd) { $script:FrontendLintCmd = $lintCmd }
  }
  Write-Host "  🔍 ${Side}: 识别到 $Tag → $stack"
}

# 把 param 提升为 script 作用域,便于 Apply-Preset 修改
$script:BackendDir      = $BackendDir
$script:FrontendDir     = $FrontendDir
$script:BackendStack    = $BackendStack
$script:FrontendStack   = $FrontendStack
$script:BackendTestCmd  = $BackendTestCmd
$script:FrontendTestCmd = $FrontendTestCmd
$script:BackendLintCmd  = $BackendLintCmd
$script:FrontendLintCmd = $FrontendLintCmd

$script:BackendDir  = Ask "后端目录(相对项目根)" $script:BackendDir  "backend"
$script:FrontendDir = Ask "前端目录(相对项目根)" $script:FrontendDir "frontend"

Write-Host ""
Write-Host "🔎 识别技术栈..."
$beTag = Detect-Stack (Join-Path $ProjectRoot $script:BackendDir)
$feTag = Detect-Stack (Join-Path $ProjectRoot $script:FrontendDir)
Write-Host "  backend=$($script:BackendDir) → $beTag"
Write-Host "  frontend=$($script:FrontendDir) → $feTag"

if ($beTag -ne "empty" -and $beTag -ne "unknown") { Apply-Preset $beTag "backend" }
if ($feTag -ne "empty" -and $feTag -ne "unknown") { Apply-Preset $feTag "frontend" }

# Apply-StackPreset: 把 --Stack flag 接受的命名预设展开为两次 Apply-Preset
function Apply-StackPreset([string]$Preset) {
  switch ($Preset) {
    { $_ -in @("python","python-light","python-pip") } {
      Apply-Preset "python-pip"    "backend"; Apply-Preset "node-frontend" "frontend"; return
    }
    "python-poetry" {
      Apply-Preset "python-poetry" "backend"; Apply-Preset "node-frontend" "frontend"; return
    }
    { $_ -in @("java","java-enterprise","java-maven") } {
      Apply-Preset "maven-java"    "backend"; Apply-Preset "node-frontend" "frontend"; return
    }
    "java-gradle" {
      Apply-Preset "gradle-java"   "backend"; Apply-Preset "node-frontend" "frontend"; return
    }
    "go" {
      Apply-Preset "go"            "backend"; Apply-Preset "node-frontend" "frontend"; return
    }
    { $_ -in @("node","node-fullstack","fullstack-node") } {
      Apply-Preset "node-backend"  "backend"; Apply-Preset "nextjs"        "frontend"; return
    }
    default {
      Write-Host "  ⚠️  未知 -Stack '$Preset', 支持: python-light|python-poetry|java-enterprise|java-gradle|go|node-fullstack"
    }
  }
}

# 优先级: -Stack > env > 工作目录探测 > 交互 choose > -Yes 模式空目录 python-light 兜底
if ($Stack -and -not $script:BackendStack -and -not $script:FrontendStack) {
  Write-Host "  🎯 应用 -Stack '$Stack'"
  Apply-StackPreset $Stack
}

if (-not $script:BackendStack -and -not $script:FrontendStack) {
  if ($Yes) {
    Write-Host "  🌱 -Yes 模式空目录: 应用默认 python-light (FastAPI + Vite+React)"
    Write-Host "     如需其他栈请用 -Stack <preset>"
    Apply-StackPreset "python-light"
  } else {
    Write-Host ""
    Write-Host "📦 未检测到代码 — 选一个起手栈:"
    Write-Host ""
    Write-Host "  ── 中小项目 / 个人项目 / 内部工具 (推荐轻量栈):"
    Write-Host "    1) Python FastAPI + Vite+React              [默认]  对齐 choseStock 实战栈"
    Write-Host "    2) Python FastAPI (Poetry) + Vite+React              用 poetry 管包"
    Write-Host "  ── 中型企业 / 团队协作:"
    Write-Host "    3) Go (Gin) + Vite+React                             高性能轻量"
    Write-Host "    4) Node.js (Fastify) + Next.js                       全栈 JS"
    Write-Host "  ── 重型企业 / 大型系统:"
    Write-Host "    5) Java (Spring Boot 3 / Maven) + Vite+React         传统重型 Java"
    Write-Host "    6) Java (Spring Boot 3 / Gradle) + Vite+React"
    Write-Host ""
    Write-Host "    9) 跳过 — 后续手动 Ask 每一项"
    $c = Read-Host "选择 [1]"
    if (-not $c) { $c = "1" }
    switch ($c) {
      "1" { Apply-StackPreset "python-light"    }
      "2" { Apply-StackPreset "python-poetry"   }
      "3" { Apply-StackPreset "go"              }
      "4" { Apply-StackPreset "node-fullstack"  }
      "5" { Apply-StackPreset "java-enterprise" }
      "6" { Apply-StackPreset "java-gradle"     }
      default { Write-Host "  跳过预设" }
    }
  }
}

# Ask 兜底默认值: 也改成 FastAPI 系 (preset 失败 / 未覆盖某项时兜底是轻量)
$script:BackendStack    = Ask "后端技术栈"     $script:BackendStack    "FastAPI + SQLAlchemy"
$script:FrontendStack   = Ask "前端技术栈"     $script:FrontendStack   "Vite + React"
$script:BackendTestCmd  = Ask "后端测试命令"   $script:BackendTestCmd  "pytest"
$script:FrontendTestCmd = Ask "前端测试命令"   $script:FrontendTestCmd "npm test"
$script:BackendLintCmd  = Ask "后端 lint 命令" $script:BackendLintCmd  "ruff check ."
$script:FrontendLintCmd = Ask "前端 lint 命令" $script:FrontendLintCmd "npm run lint"
$ApiContractPath        = Ask "现有 API 契约路径(可空)" $ApiContractPath ""

# ---------- 1. 创建目录骨架 ----------
Write-Host ""
Write-Host "📁 创建目录骨架(v2)..."
$dirs = @(
  ".aiagents\bin",
  ".aiagents\signals",
  ".aiagents\logs",
  ".aiagents\state",
  ".aiagents\runtime\heartbeats",
  ".aiagents\memory\global",
  ".aiagents\memory\projects",
  ".aiagents\memory\ideas",
  "docs\ai-agents\specs",
  "docs\ai-agents\reviews",
  "docs\ai-agents\retrospectives",
  ".claude\commands",
  ".claude\hooks"
)
foreach ($dir in $dirs) {
  New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot $dir) | Out-Null
}

# ---------- 2. 复制 .aiagents/bin ----------
Write-Host "📜 安装 .aiagents/bin 脚本..."
Copy-TemplateDir (Join-Path $TemplateRoot ".aiagents\bin") (Join-Path $ProjectRoot ".aiagents\bin")

# ---------- 3. memory 模板(已存在不覆盖) ----------
Write-Host "🧠 安装 memory 模板(保留已有)..."
Get-ChildItem -Path (Join-Path $TemplateRoot ".aiagents\memory") -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring((Join-Path $TemplateRoot ".aiagents\memory").Length).TrimStart("\", "/")
  $dest = Join-Path (Join-Path $ProjectRoot ".aiagents\memory") $rel
  if (-not (Test-Path $dest)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -Force -LiteralPath $_.FullName -Destination $dest
  }
}

# ---------- 4. slash commands ----------
Write-Host "⚡ 安装 slash commands..."
Get-ChildItem -Path (Join-Path $TemplateRoot ".claude\commands") -File | ForEach-Object {
  $tgt = Join-Path $ProjectRoot ".claude\commands\$($_.Name)"
  if (Test-Path $tgt) {
    $a = Get-Content -Raw -Encoding UTF8 $_.FullName
    $b = Get-Content -Raw -Encoding UTF8 $tgt
    if ($a -ne $b) {
      $bak = "$tgt.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
      Move-Item -Force $tgt $bak
      Write-Host "  已备份现有 $($_.Name) → $(Split-Path $bak -Leaf)"
      Copy-Item -Force $_.FullName $tgt
    }
  } else {
    Copy-Item -Force $_.FullName $tgt
  }
}

# 清理 v1 hook
$hookDir = Join-Path $ProjectRoot ".claude\hooks"
$hadV1Hook = (Test-Path (Join-Path $hookDir "stop-notify.sh")) -or (Test-Path (Join-Path $hookDir "dispatch.sh")) -or (Test-Path (Join-Path $hookDir "status.sh"))
if ($hadV1Hook) {
  $bak = "$hookDir.v1.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
  Move-Item -Force $hookDir $bak
  New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
  Write-Host "🗑️  备份 v1 .claude/hooks/ → $(Split-Path $bak -Leaf)"
}

# ---------- 5. agents.conf(向后兼容) ----------
$confPath = Join-Path $ProjectRoot ".claude\agents.conf"
if (Test-Path $confPath) {
  Write-Host "🔧 .claude\agents.conf 已存在,保留不覆盖。"
} else {
  Write-Host "🔧 生成 .claude\agents.conf(向后兼容,KV 格式)..."
  $confContent = @"
# 三 Agent 协作工作流 — 项目级配置(被 hook 脚本 source,向后兼容 v1)
# v2 起 .aiagents/config.json 是 single source of truth,本文件仅做 fallback。
BACKEND_DIR="$($script:BackendDir)"
FRONTEND_DIR="$($script:FrontendDir)"
BACKEND_TEST_CMD="$($script:BackendTestCmd)"
FRONTEND_TEST_CMD="$($script:FrontendTestCmd)"
BACKEND_LINT_CMD="$($script:BackendLintCmd)"
FRONTEND_LINT_CMD="$($script:FrontendLintCmd)"
BACKEND_STACK="$($script:BackendStack)"
FRONTEND_STACK="$($script:FrontendStack)"
CODEX_BIN="$CodexBin"
CODEX_ARGS="$CodexArgs"
MAX_RETRY=3
CODEX_TIMEOUT=$CodexTimeout
"@
  Write-Utf8File $confPath $confContent
}

# ---------- 6. .aiagents/config.json ----------
Write-Host "🧩 生成 .aiagents/config.json..."
$config = [ordered]@{
  version   = "2.0.0"
  namespace = "ai-agents-kit"
  backend   = [ordered]@{ dir = $script:BackendDir;  stack = $script:BackendStack;  test_cmd = $script:BackendTestCmd;  lint_cmd = $script:BackendLintCmd }
  frontend  = [ordered]@{ dir = $script:FrontendDir; stack = $script:FrontendStack; test_cmd = $script:FrontendTestCmd; lint_cmd = $script:FrontendLintCmd }
  codex     = [ordered]@{ bin = $CodexBin; args = $CodexArgs; timeout_seconds = $CodexTimeout }
  workflow  = [ordered]@{ max_retry = 3; require_review_before_frontend = $true; human_override_after_retry = 3 }
  paths     = [ordered]@{
    specs = "docs/ai-agents/specs"
    reviews = "docs/ai-agents/reviews"
    retrospectives = "docs/ai-agents/retrospectives"
    signals = ".aiagents/signals"
    logs = ".aiagents/logs"
    state = ".aiagents/state"
    memory = ".aiagents/memory"
  }
}
Write-Utf8File (Join-Path $ProjectRoot ".aiagents\config.json") ($config | ConvertTo-Json -Depth 10)

# ---------- 7. settings.json 合并 ----------
Write-Host "🧩 合并 .claude\settings.json..."
$settingsPath = Join-Path $ProjectRoot ".claude\settings.json"
$tmplSettingsPath = Join-Path $TemplateRoot ".claude\settings.json"
$tmplSettings = Get-Content -Raw -Encoding UTF8 $tmplSettingsPath | ConvertFrom-Json

if (Test-Path $settingsPath) {
  $existing = Get-Content -Raw -Encoding UTF8 $settingsPath | ConvertFrom-Json
} else {
  $existing = [pscustomobject]@{}
}

# Stop hooks
if (-not $existing.PSObject.Properties["hooks"]) { $existing | Add-Member -MemberType NoteProperty -Name hooks -Value ([pscustomobject]@{}) }
if (-not $existing.hooks.PSObject.Properties["Stop"]) { $existing.hooks | Add-Member -MemberType NoteProperty -Name Stop -Value @() }

$stopList = New-Object System.Collections.ArrayList
foreach ($hook in @($existing.hooks.Stop)) {
  if ($null -eq $hook) { continue }
  $cmdJson = $hook | ConvertTo-Json -Compress -Depth 6
  # 跳过 v1 旧路径的 hook
  if ($cmdJson -match '\.claude/hooks/stop-notify\.sh') { continue }
  [void]$stopList.Add($hook)
}
foreach ($newHook in @($tmplSettings.hooks.Stop)) {
  $exists = $false
  foreach ($h in $stopList) {
    if (($h | ConvertTo-Json -Compress -Depth 6) -eq ($newHook | ConvertTo-Json -Compress -Depth 6)) { $exists = $true; break }
  }
  if (-not $exists) { [void]$stopList.Add($newHook) }
}
$existing.hooks | Add-Member -MemberType NoteProperty -Name Stop -Value @($stopList.ToArray()) -Force

# permissions.allow
if (-not $existing.PSObject.Properties["permissions"]) { $existing | Add-Member -MemberType NoteProperty -Name permissions -Value ([pscustomobject]@{}) }
if (-not $existing.permissions.PSObject.Properties["allow"]) { $existing.permissions | Add-Member -MemberType NoteProperty -Name allow -Value @() }
$allow = @($existing.permissions.allow)
foreach ($item in @($tmplSettings.permissions.allow)) {
  if ($allow -notcontains $item) { $allow += $item }
}
$existing.permissions | Add-Member -MemberType NoteProperty -Name allow -Value $allow -Force

Write-Utf8File $settingsPath ($existing | ConvertTo-Json -Depth 20)

# ---------- 8. CLAUDE.md(v1→v2) ----------
Write-Host "📝 同步 CLAUDE.md 三 Agent 章节..."
$claudePath = Join-Path $ProjectRoot "CLAUDE.md"
$tmplClaudeRaw = Get-Content -Raw -Encoding UTF8 (Join-Path $TemplateRoot "CLAUDE.md")
$apiPath = if ($ApiContractPath) { $ApiContractPath } else { "(无)" }
$rendered = $tmplClaudeRaw `
  -replace [regex]::Escape("<BACKEND_STACK>"), $script:BackendStack `
  -replace [regex]::Escape("<FRONTEND_STACK>"), $script:FrontendStack `
  -replace [regex]::Escape("<BACKEND_TEST_CMD>"), $script:BackendTestCmd `
  -replace [regex]::Escape("<FRONTEND_TEST_CMD>"), $script:FrontendTestCmd `
  -replace [regex]::Escape("<BACKEND_LINT_CMD>"), $script:BackendLintCmd `
  -replace [regex]::Escape("<FRONTEND_LINT_CMD>"), $script:FrontendLintCmd `
  -replace [regex]::Escape("<API_CONTRACT_PATH>"), $apiPath

if (Test-Path $claudePath) {
  $old = Get-Content -Raw -Encoding UTF8 $claudePath
  if ($old.Contains($MarkerStartV2)) {
    $pattern = [regex]::Escape($MarkerStartV2) + "(.|\n|\r)*?" + [regex]::Escape($MarkerEndV2)
    $new = [regex]::Replace($old, $pattern, [System.Text.RegularExpressions.Regex]::Escape($rendered).Replace('\','\\'))
    # 上面 Escape 会让 $ 等被转义,改用 -replace 的回调更安全
    $new = $old -replace $pattern, ([regex]::Escape($rendered) -replace '\\','\\\\')
    # 简化方案: 直接 Substring 拼接
    $startIdx = $old.IndexOf($MarkerStartV2)
    $endIdx = $old.IndexOf($MarkerEndV2)
    if ($endIdx -ge 0) {
      $endIdx = $endIdx + $MarkerEndV2.Length
      $new = $old.Substring(0, $startIdx) + $rendered + $old.Substring($endIdx)
    } else {
      $new = $old + "`n`n" + $rendered
    }
    Write-Utf8File $claudePath $new
    Write-Host "  已就地升级 v2 章节"
  } elseif ($old.Contains($MarkerStartV1)) {
    $bak = "$claudePath.v1.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    Copy-Item -Force $claudePath $bak
    $startIdx = $old.IndexOf($MarkerStartV1)
    $endIdx = $old.IndexOf($MarkerEndV1)
    if ($endIdx -ge 0) {
      $endIdx = $endIdx + $MarkerEndV1.Length
      $new = $old.Substring(0, $startIdx) + $rendered + $old.Substring($endIdx)
    } else {
      $new = $old.Substring(0, $startIdx) + $rendered
    }
    Write-Utf8File $claudePath $new
    Write-Host "  备份 v1 → $(Split-Path $bak -Leaf),已升级为 v2"
  } else {
    Add-Content -Encoding UTF8 -Path $claudePath -Value "`n`n$rendered"
    Write-Host "  已追加 v2 章节到已有 CLAUDE.md"
  }
} else {
  Write-Utf8File $claudePath $rendered
  Write-Host "  已新建 CLAUDE.md"
}

# ---------- 9. start-agents.sh ----------
$startPath = Join-Path $ProjectRoot "start-agents.sh"
if ((Test-Path $startPath) -and -not ((Get-Content -Raw -Encoding UTF8 $startPath) -match "ai-agents-kit")) {
  Move-Item -Force $startPath "$startPath.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
  Write-Host "🪟 备份已有 start-agents.sh"
}
Copy-Item -Force (Join-Path $TemplateRoot "start-agents.sh") $startPath

# ---------- 10. .gitignore ----------
$gi = Join-Path $ProjectRoot ".gitignore"
if (-not (Test-Path $gi)) { Write-Utf8File $gi "" }
$existingIgnore = Get-Content -Encoding UTF8 $gi -ErrorAction SilentlyContinue
$newIgnoreLines = @(
  ".aiagents/signals/",
  ".aiagents/logs/",
  ".aiagents/state/",
  ".aiagents/runtime/",
  "docs/ai-agents/specs/.consumed_*",
  "docs/superpowers/signals/",
  "docs/superpowers/logs/",
  "docs/superpowers/specs/.consumed_*"
)
foreach ($line in $newIgnoreLines) {
  if ($existingIgnore -notcontains $line) {
    Add-Content -Encoding UTF8 -Path $gi -Value $line
  }
}

# ---------- 11. 操作手册 ----------
Copy-Item -Force (Join-Path $TemplateRoot "docs\ai-agents\README.md") (Join-Path $ProjectRoot "docs\ai-agents\README.md") -ErrorAction SilentlyContinue

# ---------- 12. v1 → v2 迁移 ----------
if ($MigrateV1) {
  Write-Host ""
  Write-Host "🚚 v1 → v2 数据迁移..."
  $old = Join-Path $ProjectRoot "docs\superpowers"

  if (Test-Path (Join-Path $old "specs")) {
    Get-ChildItem -Path (Join-Path $old "specs") -Force | ForEach-Object {
      $tgt = Join-Path $ProjectRoot "docs\ai-agents\specs\$($_.Name)"
      if (-not (Test-Path $tgt)) { Move-Item -Force $_.FullName $tgt; Write-Host "  specs: $($_.Name)" }
    }
  }
  if (Test-Path (Join-Path $old "signals")) {
    Get-ChildItem -Path (Join-Path $old "signals") -Force | ForEach-Object {
      $tgt = Join-Path $ProjectRoot ".aiagents\signals\$($_.Name)"
      if (-not (Test-Path $tgt)) { Move-Item -Force $_.FullName $tgt -ErrorAction SilentlyContinue }
    }
  }
  if (Test-Path (Join-Path $old "logs")) {
    Get-ChildItem -Path (Join-Path $old "logs") -Force | ForEach-Object {
      $tgt = Join-Path $ProjectRoot ".aiagents\logs\$($_.Name)"
      if (-not (Test-Path $tgt)) { Move-Item -Force $_.FullName $tgt }
    }
  }
  if (Test-Path (Join-Path $old "bin")) {
    $binBak = Join-Path $old "bin.v1.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    Move-Item -Force (Join-Path $old "bin") $binBak
    Write-Host "  备份旧 bin/ → $(Split-Path $binBak -Leaf)"
  }
  Write-Utf8File (Join-Path $old "MIGRATED.md") @"
# v1 → v2 已迁移

本目录已经迁移到:
- specs/   → docs/ai-agents/specs/
- signals/ → .aiagents/signals/
- logs/    → .aiagents/logs/
- bin/     → 不再使用

可以安全删除本目录。
"@
  Write-Host "  迁移完成。"
}

# ---------- 13. STACK 一致性检查 ----------
$warnings = New-Object System.Collections.ArrayList
function Test-Consistency([string]$Side, [string]$Stack, [string]$Test, [string]$Lint) {
  $sLc = $Stack.ToLower(); $tLc = $Test.ToLower(); $lLc = $Lint.ToLower()
  $expected = ""
  if ($sLc -match "python|fastapi|django|flask")        { $expected = "python" }
  elseif ($sLc -match "spring|java|maven")              { $expected = "maven" }
  elseif ($sLc -match "gradle")                         { $expected = "gradle" }
  elseif ($sLc -match "next|nuxt|vite|react|vue|svelte|node|express|fastify") { $expected = "node" }
  elseif ($sLc -match "\bgo\b|golang|gin")              { $expected = "go" }
  elseif ($sLc -match "rust|cargo|axum")                { $expected = "cargo" }
  else {
    [void]$warnings.Add("$Side: STACK=`"$Stack`" 未识别,无法校验 TEST/LINT 一致性")
    return
  }
  $actual = ""
  if ($tLc -match "pytest|poetry|python")    { $actual = "python" }
  elseif ($tLc -match "mvnw|maven|mvn ")     { $actual = "maven" }
  elseif ($tLc -match "gradlew|gradle")      { $actual = "gradle" }
  elseif ($tLc -match "npm|yarn|pnpm|node")  { $actual = "node" }
  elseif ($tLc -match "go test|go vet")      { $actual = "go" }
  elseif ($tLc -match "cargo")               { $actual = "cargo" }
  if ($actual -and $expected -ne $actual) {
    [void]$warnings.Add("$Side: STACK=`"$Stack`" 像 $expected,但 TEST_CMD=`"$Test`" 是 $actual → 不一致")
  }
}
Test-Consistency "backend"  $script:BackendStack  $script:BackendTestCmd  $script:BackendLintCmd
Test-Consistency "frontend" $script:FrontendStack $script:FrontendTestCmd $script:FrontendLintCmd
if ($warnings.Count -gt 0) {
  Write-Host ""
  Write-Host "⚠️  一致性警告 — 请确认 .aiagents\config.json 的 TEST/LINT 与 STACK 匹配:"
  foreach ($w in $warnings) { Write-Host "    - $w" }
}

# ---------- 14. 完成 ----------
Write-Host ""
Write-Host "==========================================="
if ($MigrateV1) { Write-Host "✅ v1 → v2 迁移完成" } else { Write-Host "✅ 安装完成" }
Write-Host "==========================================="
Write-Host ""
Write-Host "  PowerShell 启动:"
Write-Host "    面板 1> claude ."
Write-Host "    面板 2> pwsh .aiagents\bin\agentctl.ps1 watch backend"
Write-Host "    面板 3> pwsh .aiagents\bin\agentctl.ps1 watch frontend"
Write-Host ""
Write-Host "  Bash 等价(Cursor/Git Bash):"
Write-Host "    bash .aiagents/bin/agentctl.sh watch backend"
Write-Host ""
Write-Host "  常用命令:"
Write-Host "    pwsh .aiagents\bin\agentctl.ps1 status"
Write-Host "    pwsh .aiagents\bin\agentctl.ps1 dispatch backend"
Write-Host "    pwsh .aiagents\bin\agentctl.ps1 memory `"一条经验`""
Write-Host ""
Write-Host "  手册: $ProjectRoot\docs\ai-agents\README.md"
Write-Host "  配置: $ProjectRoot\.aiagents\config.json + $confPath"
