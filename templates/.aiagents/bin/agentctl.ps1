#requires -Version 5.1
# ai-agents-kit v2: PowerShell 控制入口。Bash 入口 agentctl.sh 的 1:1 等价物。
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet("up", "start", "down", "stop", "restart", "status", "logs", "dispatch", "wait", "watch", "memory", "release-without-verify")]
  [string]$Command = "status",

  [Parameter(Position = 1)]
  [string]$Target = "backend",

  [int]$WaitSeconds = 540,

  [Parameter()]
  [string]$Provider = "",

  [Parameter()]
  [int]$Timeout = 0,

  [Parameter()]
  [string]$Reason = "",

  [Parameter(Position = 2)]
  [string]$LogKind = "pretty"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Get-ProjectRoot {
  $root = (& git rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -eq 0 -and $root) { return $root.Trim() }
  return (Get-Location).Path
}

function Write-Utf8File([string]$Path, [string]$Content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

$ProjectRoot = Get-ProjectRoot
$ConfigPath = Join-Path $ProjectRoot ".aiagents\config.json"
$ConfPath = Join-Path $ProjectRoot ".claude\agents.conf"

# 配置加载: 优先 config.json, 回退到 agents.conf KV 格式
function Read-Config {
  if (Test-Path $ConfigPath) {
    return (Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json)
  }
  if (Test-Path $ConfPath) {
    $cfg = @{}
    Get-Content -Encoding UTF8 $ConfPath | ForEach-Object {
      if ($_ -match '^([A-Z_]+)="?([^"]*)"?$') { $cfg[$Matches[1]] = $Matches[2] }
    }
    return [pscustomobject]@{
      backend  = [pscustomobject]@{ dir = $cfg["BACKEND_DIR"]; stack = $cfg["BACKEND_STACK"]; test_cmd = $cfg["BACKEND_TEST_CMD"]; lint_cmd = $cfg["BACKEND_LINT_CMD"] }
      frontend = [pscustomobject]@{ dir = $cfg["FRONTEND_DIR"]; stack = $cfg["FRONTEND_STACK"]; test_cmd = $cfg["FRONTEND_TEST_CMD"]; lint_cmd = $cfg["FRONTEND_LINT_CMD"] }
      codex    = [pscustomobject]@{ bin = ($cfg["CODEX_BIN"] | ForEach-Object { if ($_) { $_ } else { "codex" } }); args = ($cfg["CODEX_ARGS"] | ForEach-Object { if ($_) { $_ } else { "--sandbox danger-full-access --skip-git-repo-check" } }); timeout_seconds = [int]($cfg["CODEX_TIMEOUT"]) }
      workflow = [pscustomobject]@{ max_retry = [int]($cfg["MAX_RETRY"]) }
      paths    = [pscustomobject]@{ specs = "docs/ai-agents/specs"; reviews = "docs/ai-agents/reviews"; retrospectives = "docs/ai-agents/retrospectives"; signals = ".aiagents/signals"; logs = ".aiagents/logs"; state = ".aiagents/state"; memory = ".aiagents/memory" }
    }
  }
  throw "找不到 .aiagents\config.json 或 .claude\agents.conf,请先运行 install.ps1 / install.sh"
}

$Config = Read-Config

$SignalDir = Join-Path $ProjectRoot $Config.paths.signals
$LogDir    = Join-Path $ProjectRoot $Config.paths.logs
$StateDir  = Join-Path $ProjectRoot $Config.paths.state
$MemoryDir = Join-Path $ProjectRoot $Config.paths.memory
$SpecDir   = Join-Path $ProjectRoot $Config.paths.specs
$BinDir    = Join-Path $ProjectRoot ".aiagents\bin"
$RuntimeDir = Join-Path $ProjectRoot ".aiagents\runtime"
foreach ($dir in @($SignalDir, $LogDir, $StateDir, $MemoryDir, $SpecDir, (Join-Path $RuntimeDir "heartbeats"))) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# Change 6: Preserve claude-verifying / ready-for-human states across signal-driven state writes
function Get-AgentState([string]$Agent) {
  if (Test-Path (Join-Path $SignalDir "task_ready_$Agent")) { return "queued" }
  if (Test-Path (Join-Path $SignalDir "bugfix_$Agent")) { return "queued-bugfix" }
  if (Test-Path (Join-Path $SignalDir "${Agent}_done")) { return "done-awaiting-review" }
  if (Test-Path (Join-Path $SignalDir "${Agent}_failed")) { return "failed" }
  if (Test-Path (Join-Path $SignalDir "${Agent}_timeout")) { return "timeout" }
  # Preserve verifying/ready-for-human if no signal overrides
  $statePath = Join-Path $StateDir "current.json"
  if (Test-Path $statePath) {
    try {
      $current = Get-Content -Raw -Encoding UTF8 $statePath | ConvertFrom-Json
      if ($current.PSObject.Properties[$Agent]) {
        $s = $current.$Agent.state
        if ($s -in @("claude-verifying","ready-for-human")) { return $s }
      }
    } catch {}
  }
  return "idle"
}

function Get-WorkerState([string]$Agent) {
  $workersPath = Join-Path $RuntimeDir "workers.json"
  $heartbeatPath = Join-Path $RuntimeDir "heartbeats\$Agent.json"
  $entry = @{}
  if (Test-Path $workersPath) {
    try {
      $workers = Get-Content -Raw -Encoding UTF8 $workersPath | ConvertFrom-Json
      if ($workers.PSObject.Properties[$Agent]) {
        $workers.$Agent.PSObject.Properties | ForEach-Object { $entry[$_.Name] = $_.Value }
      }
    } catch {}
  }
  if (Test-Path $heartbeatPath) {
    try {
      $heartbeat = Get-Content -Raw -Encoding UTF8 $heartbeatPath | ConvertFrom-Json
      $entry["last_heartbeat"] = $heartbeat.updated_at
      if ($entry["status"] -eq "running") {
        $last = [DateTimeOffset]::Parse($heartbeat.updated_at)
        if (([DateTimeOffset]::Now - $last).TotalSeconds -gt 10) { $entry["status"] = "stale" }
      }
    } catch {
      if ($entry["status"] -eq "running") { $entry["status"] = "stale" }
    }
  } elseif ($entry["status"] -eq "running") {
    $entry["status"] = "stale"
  }
  if (-not $entry.ContainsKey("status")) { $entry["status"] = "stopped" }
  return $entry
}

function Write-StateSnapshot {
  $snapshot = [ordered]@{
    updated_at   = (Get-Date).ToString("o")
    project_root = $ProjectRoot
    backend  = [ordered]@{ dir = $Config.backend.dir;  stack = $Config.backend.stack;  state = (Get-AgentState "backend") }
    frontend = [ordered]@{ dir = $Config.frontend.dir; stack = $Config.frontend.stack; state = (Get-AgentState "frontend") }
    workers  = [ordered]@{ backend = (Get-WorkerState "backend"); frontend = (Get-WorkerState "frontend") }
    workflow = $Config.workflow
    paths    = $Config.paths
  }
  Write-Utf8File (Join-Path $StateDir "current.json") ($snapshot | ConvertTo-Json -Depth 10)
}

function Append-Event([string]$Agent, [string]$Status, [string]$Message, [hashtable]$Extra = @{}) {
  $event = [ordered]@{
    time    = (Get-Date).ToString("o")
    agent   = $Agent
    status  = $Status
    message = $Message
  }
  foreach ($key in $Extra.Keys) { $event[$key] = $Extra[$key] }
  Add-Content -Path (Join-Path $StateDir "events.jsonl") -Encoding UTF8 -Value ($event | ConvertTo-Json -Compress -Depth 8)
  Write-StateSnapshot
}

function Get-SpecPath([string]$Kind) {
  switch ($Kind) {
    "backend" {
      $p = Join-Path $SpecDir "02-后端编码.md"
      if (Test-Path $p) { return $p } else { return Join-Path $SpecDir "02-backend.md" }
    }
    "frontend" {
      $p = Join-Path $SpecDir "03-前端编码.md"
      if (Test-Path $p) { return $p } else { return Join-Path $SpecDir "03-frontend.md" }
    }
    "bugfix-backend" {
      $p = Join-Path $SpecDir "04-Bug修复-backend.md"
      if (Test-Path $p) { return $p } else { return Join-Path $SpecDir "04-bugfix-backend.md" }
    }
    "bugfix-frontend" {
      $p = Join-Path $SpecDir "04-Bug修复-frontend.md"
      if (Test-Path $p) { return $p } else { return Join-Path $SpecDir "04-bugfix-frontend.md" }
    }
    default { throw "未知目标: $Kind" }
  }
}

function Get-SignalPath([string]$Kind) {
  switch ($Kind) {
    "backend" { return Join-Path $SignalDir "task_ready_backend" }
    "frontend" { return Join-Path $SignalDir "task_ready_frontend" }
    "bugfix-backend" { return Join-Path $SignalDir "bugfix_backend" }
    "bugfix-frontend" { return Join-Path $SignalDir "bugfix_frontend" }
    default { throw "未知目标: $Kind" }
  }
}

# Change 2: Dispatch-Agent accepts Provider/Timeout overrides
function Dispatch-Agent([string]$Kind, [string]$ProviderOverride = "", [int]$TimeoutOverride = 0) {
  # Validate provider if given
  if ($ProviderOverride) {
    if ($Config.PSObject.Properties["providers"]) {
      if (-not $Config.providers.PSObject.Properties[$ProviderOverride]) {
        $available = ($Config.providers.PSObject.Properties | Select-Object -ExpandProperty Name) -join ", "
        throw "未知 provider: '$ProviderOverride'。可用: $available"
      }
    } else {
      Write-Warning "config.json 中无 providers 配置,忽略 --provider 参数(v2 兼容模式)"
    }
  }

  $spec = Get-SpecPath $Kind
  if (-not (Test-Path $spec)) { throw "派发失败,规格文件不存在: $spec" }
  $signal = Get-SignalPath $Kind
  $payload = [ordered]@{
    kind             = $Kind
    spec             = $spec
    dispatched_at    = (Get-Date).ToString("o")
    provider_override = $ProviderOverride
    timeout_override  = if ($TimeoutOverride -gt 0) { "$TimeoutOverride" } else { "" }
  }
  Write-Utf8File $signal ($payload | ConvertTo-Json -Compress)
  Append-Event $Kind "dispatched" "任务已派发" @{ spec = $spec; signal = $signal; provider_override = $ProviderOverride; timeout_override = if ($TimeoutOverride -gt 0) { "$TimeoutOverride" } else { "" } }
  Write-Host "已派发 $Kind"
  Write-Host "   信号: $signal"
  Write-Host "   spec: $spec"
  if ($ProviderOverride) { Write-Host "   provider: $ProviderOverride" }
  if ($TimeoutOverride -gt 0) { Write-Host "   timeout: ${TimeoutOverride}s" }
}

function Consume-Signal([string]$Path) {
  $name = Split-Path $Path -Leaf
  $dest = Join-Path $SignalDir (".consumed_{0}_{1}" -f $name, (Get-Date -Format "yyyyMMdd_HHmmss"))
  Move-Item -Force -Path $Path -Destination $dest
}

function Wait-Agent([string]$Agent, [int]$MaxSeconds) {
  $start = Get-Date
  Write-Host "⏳ 等待编码 agent-$Agent 完成信号(最长 ${MaxSeconds}s)..."
  while ($true) {
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    foreach ($suffix in @("done", "failed", "timeout")) {
      $path = Join-Path $SignalDir "${Agent}_$suffix"
      if (Test-Path $path) {
        $reason = ""
        if ($suffix -ne "done") { $reason = (Get-Content -Raw -Encoding UTF8 $path) }
        Consume-Signal $path
        Append-Event $Agent $suffix "检测到 ${Agent}_$suffix" @{ elapsed_seconds = $elapsed; reason = $reason }
        if ($suffix -eq "done") { Write-Host ""; Write-Host "✅ $Agent 完成"; exit 0 }
        if ($suffix -eq "failed") { Write-Host ""; Write-Host "❌ FAILED: $reason"; exit 1 }
        if ($suffix -eq "timeout") { Write-Host ""; Write-Host "⏰ TIMEOUT: $reason"; exit 2 }
      }
    }
    if ($elapsed -ge $MaxSeconds) {
      Append-Event $Agent "wait-expired" "等待超时但未收到信号" @{ elapsed_seconds = $elapsed }
      Write-Host ""
      Write-Host "⚠️ 等待 ${MaxSeconds}s 仍无信号 — 编码 agent 可能仍在运行(Stop hook 兜底)"
      exit 3
    }
    Start-Sleep -Seconds 3
  }
}

# Change 4: Invoke-CodexTask shells out to bash agent-runner.sh
function Invoke-CodexTask([string]$Agent, [string]$Mode) {
  # Mode is "task" or "bugfix"
  $runner = Join-Path $BinDir "agent-runner.sh"
  if (-not (Test-Path $runner)) {
    Write-Utf8File (Join-Path $SignalDir "${Agent}_failed") "agent-runner.sh 不存在: $runner"
    Append-Event $Agent "failed" "agent-runner.sh 缺失" @{ runner = $runner }
    return
  }

  # Read signal file body for provider/timeout override
  $sigName = if ($Mode -eq "task") { "task_ready_$Agent" } else { "bugfix_$Agent" }
  $sigPath = Join-Path $SignalDir $sigName
  $providerOverride = ""
  $timeoutOverride  = ""
  if (Test-Path $sigPath) {
    try {
      $body = Get-Content -Raw -Encoding UTF8 $sigPath | ConvertFrom-Json
      if ($body.provider_override) { $providerOverride = $body.provider_override }
      if ($body.timeout_override)  { $timeoutOverride  = $body.timeout_override }
    } catch {}
  }

  Append-Event $Agent "dispatched-to-runner" "委派 bash agent-runner" @{ mode = $Mode; provider_override = $providerOverride; timeout_override = $timeoutOverride }

  # Set env and shell out
  $env:PROVIDER_OVERRIDE = $providerOverride
  $env:TIMEOUT_OVERRIDE  = $timeoutOverride
  & bash $runner $Agent $Mode
  $rc = $LASTEXITCODE
  $env:PROVIDER_OVERRIDE = $null
  $env:TIMEOUT_OVERRIDE  = $null

  # agent-runner already wrote signal/state/events; we just log the rc
  Append-Event $Agent "runner-exit" "bash agent-runner 返回 rc=$rc" @{ rc = $rc }
}

function Watch-Agent([string]$Agent) {
  if ($Agent -notin @("backend", "frontend")) { throw "watch 只支持 backend/frontend" }
  Append-Event $Agent "watcher-ready" "watcher 已启动"
  Write-Host "$Agent 编码 agent watcher ready · $(Get-Date -Format o)"
  Write-Host "    监听 $SignalDir\task_ready_$Agent 和 $SignalDir\bugfix_$Agent"
  while ($true) {
    $taskSignal = Join-Path $SignalDir "task_ready_$Agent"
    $bugSignal  = Join-Path $SignalDir "bugfix_$Agent"
    # Change 4: Pass mode to Invoke-CodexTask; agent-runner consumes the signal file itself
    if (Test-Path $taskSignal) {
      Write-Host ""
      Write-Host "🔔 $(Get-Date -Format 'HH:mm:ss') 检测到 $Agent 新任务"
      Invoke-CodexTask $Agent "task"
    }
    if (Test-Path $bugSignal) {
      Write-Host ""
      Write-Host "🔧 $(Get-Date -Format 'HH:mm:ss') 检测到 $Agent 修复任务"
      Invoke-CodexTask $Agent "bugfix"
    }
    Start-Sleep -Seconds 2
  }
}

# Change 5: Get-AgentProvider for provider column in status output
function Get-AgentProvider([string]$Agent) {
  if ($Config.PSObject.Properties["agents"] -and $Config.agents.PSObject.Properties[$Agent]) {
    $p = $Config.agents.$Agent.provider
    if ($p) { return $p }
  }
  if ($Config.PSObject.Properties["default_provider"]) {
    if ($Config.default_provider) { return $Config.default_provider }
  }
  return "codex"
}

function Show-Status {
  Write-StateSnapshot
  Write-Host "=========================================="
  Write-Host "  ai-agents-kit 状态 · $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  Write-Host "=========================================="
  # Change 5: Include new states in stateMap
  $stateMap = @{
    "idle" = "空闲"; "queued" = "队列中"; "queued-bugfix" = "修复队列中"
    "running" = "进行中"; "done-awaiting-review" = "已完成,待审查"
    "claude-verifying" = "主 Claude 验证中"; "ready-for-human" = "等待 Lane 决策"
    "failed" = "失败"; "timeout" = "超时"
  }
  foreach ($agent in @("backend", "frontend")) {
    $state = Get-AgentState $agent
    $worker = Get-WorkerState $agent
    Write-Host ""
    Write-Host "[$agent] $($stateMap[$state])"
    Write-Host "   dir=$($Config.$agent.dir) stack=$($Config.$agent.stack)"
    # Change 5: Show provider column
    Write-Host "   provider=$(Get-AgentProvider $agent)"
    Write-Host "   worker=$($worker['status']) pid=$($worker['pid']) hb=$($worker['last_heartbeat'])"
    $prefix = if ($agent -eq "backend") { "be" } else { "fe" }
    $latest = Get-ChildItem -Path $LogDir -Filter "${prefix}_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
      Write-Host "--- $($latest.Name) 尾 15 行 ---"
      Get-Content -Encoding UTF8 $latest.FullName -Tail 15
    } else {
      Write-Host "(暂无日志)"
    }
  }
  Write-Host ""
  Write-Host "状态: $(Join-Path $StateDir 'current.json')"
  Write-Host "事件: $(Join-Path $StateDir 'events.jsonl')"
}

function Add-Memory([string]$Text) {
  if (-not $Text) { throw "请提供要写入的经验文本" }
  $path = Join-Path $MemoryDir "global\patterns.md"
  if (-not (Test-Path $path)) { Write-Utf8File $path "# 成功模式 (Patterns)`n`n" }
  Add-Content -Path $path -Encoding UTF8 -Value ("`n## {0}`n`n- {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $Text)
  Append-Event "memory" "captured" "写入记忆" @{ text = $Text }
  Write-Host "已写入 $path"
}

# Change 3: Release-WithoutVerify function
function Release-WithoutVerify([string]$Agent, [string]$ReleaseReason) {
  if (-not $Agent -or -not $ReleaseReason) {
    throw "用法: agentctl.ps1 -Command release-without-verify -Target <backend|frontend> -Reason '<reason>'"
  }
  if ($Agent -notin @("backend","frontend")) { throw "未知 agent: $Agent" }

  # Update state/current.json
  $statePath = Join-Path $StateDir "current.json"
  if (Test-Path $statePath) {
    $state = Get-Content -Raw -Encoding UTF8 $statePath | ConvertFrom-Json
    if ($state.PSObject.Properties[$Agent]) {
      $state.$Agent | Add-Member -NotePropertyName state -NotePropertyValue "ready-for-human" -Force
    }
    $state | Add-Member -NotePropertyName updated_at -NotePropertyValue (Get-Date).ToString("o") -Force
    Write-Utf8File $statePath ($state | ConvertTo-Json -Depth 10)
  }

  # Append bypass event
  $event = [ordered]@{
    time   = (Get-Date).ToString("o")
    agent  = $Agent
    phase  = "verify-bypassed"
    status = "ready-for-human"
    reason = $ReleaseReason
    by     = "lane"
  }
  Add-Content -Path (Join-Path $StateDir "events.jsonl") -Encoding UTF8 -Value ($event | ConvertTo-Json -Compress -Depth 8)

  # Append to memory bugs.md if exists
  $bugsPath = Join-Path $MemoryDir "global\bugs.md"
  if (Test-Path $bugsPath) {
    $section = "`n## $(Get-Date -Format 'yyyy-MM-dd HH:mm') · verify-bypass: $Agent`n`n"
    $section += "**触发**: ``-Command release-without-verify -Target $Agent -Reason '$ReleaseReason'`` 显式破例`n"
    $section += "**reason**: $ReleaseReason`n"
    $section += "**待补**: 后续阶段 review 时核对该轮是否有遗漏 bug`n"
    Add-Content -Path $bugsPath -Encoding UTF8 -Value $section
  }

  Write-Host "released without verify: agent=$Agent reason=$ReleaseReason"
}

# v3.2 一键启停 (up/down/restart) — Bash agentctl.sh 等价
function Get-AliveWorkerPid([string]$Agent) {
  $workersJson = Join-Path $RuntimeDir "workers.json"
  if (-not (Test-Path $workersJson)) { return $null }
  try {
    $d = Get-Content -Encoding UTF8 $workersJson -ErrorAction Stop | ConvertFrom-Json
    $entry = $d.$Agent
    if (-not $entry) { return $null }
    $alivePid = $entry.pid
    if (-not $alivePid) { return $null }
    if (Get-Process -Id $alivePid -ErrorAction SilentlyContinue) { return $alivePid }
  } catch { }
  return $null
}

function Watchers-Up {
  $started = 0; $already = 0
  $psHost = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
  foreach ($agent in @('backend', 'frontend')) {
    $log = Join-Path $LogDir "worker-$agent.log"
    $errLog = "$log.err"
    $alive = Get-AliveWorkerPid $agent
    if ($alive) {
      Write-Host "ℹ️  $agent watcher 已在跑 (pid=$alive, log=$log) — 跳过"
      $already++
      continue
    }
    $proc = Start-Process -FilePath $psHost `
      -ArgumentList "-NoProfile","-NonInteractive","-File",$PSCommandPath,"watch",$agent `
      -RedirectStandardOutput $log `
      -RedirectStandardError $errLog `
      -WindowStyle Hidden -PassThru
    Write-Host "✅ $agent watcher 启动 pid=$($proc.Id) · log=$log"
    $started++
  }
  Write-Host ""
  Write-Host "总计: $started 个新启动 / $already 个已在跑"
  if ($started -gt 0) {
    Write-Host "提示: pwsh $PSCommandPath status 可查实时状态;关闭当前窗口不影响后台 watcher (Start-Process 已脱离控制台)"
  }
}

function Watchers-Down {
  $stopped = 0; $absent = 0
  foreach ($agent in @('backend', 'frontend')) {
    $alive = Get-AliveWorkerPid $agent
    if (-not $alive) {
      Write-Host "ℹ️  $agent: 没有活动的 watcher"
      $absent++
      continue
    }
    try {
      Stop-Process -Id $alive -Force -ErrorAction Stop
      Write-Host "✅ $agent watcher 已停止 (pid=$alive)"
      $stopped++
    } catch {
      Write-Host "⚠️  $agent: 停 pid=$alive 失败: $_"
    }
  }
  Write-Host ""
  Write-Host "总计: $stopped 个已停 / $absent 个已无"
}

# v3.2.1 日志监控 (logs) — Bash agentctl.sh 等价
function Get-LogPath([string]$Agent, [string]$Kind = 'pretty') {
  $abbr = if ($Agent -eq 'frontend') { 'fe' } else { 'be' }
  $today = Get-Date -Format 'yyyyMMdd'
  switch ($Kind) {
    'pretty' { return Join-Path $LogDir "${abbr}_${today}.log" }
    'worker' { return Join-Path $LogDir "worker-${Agent}.log" }
    'raw'    { return Join-Path $LogDir "${abbr}_${today}.log.raw" }
    default  { return $null }
  }
}

function Logs-Snapshot {
  Write-Host "==========================================="
  Write-Host "  日志路径 + 末尾快照 (logs <agent> 可 follow)"
  Write-Host "==========================================="
  foreach ($agent in @('backend', 'frontend')) {
    Write-Host ""
    Write-Host "[$agent]"
    foreach ($kind in @('pretty', 'worker', 'raw')) {
      $p = Get-LogPath $agent $kind
      if (Test-Path $p) {
        $size = (Get-Item $p).Length
        Write-Host ("  {0,-7} {1} ({2} bytes)" -f "${kind}:", $p, $size)
      } else {
        Write-Host ("  {0,-7} {1} (不存在)" -f "${kind}:", $p)
      }
    }
    $pp = Get-LogPath $agent 'pretty'
    if (Test-Path $pp) {
      Write-Host "  --- pretty 尾 5 行 ---"
      Get-Content -Path $pp -Tail 5 -Encoding UTF8 | ForEach-Object { Write-Host "    $_" }
    }
  }
  Write-Host ""
  Write-Host "follow 用法:"
  Write-Host "  pwsh $PSCommandPath logs backend           # 跟 backend pretty"
  Write-Host "  pwsh $PSCommandPath logs frontend          # 跟 frontend pretty"
  Write-Host "  pwsh $PSCommandPath logs both              # 双 agent 同时跟"
  Write-Host "  pwsh $PSCommandPath logs backend worker    # 跟 watcher 自身输出"
  Write-Host "  pwsh $PSCommandPath logs backend raw       # 跟 claude 原始 JSON"
}

# logs follow 默认过滤 stream-json 残留行 — pretty kind 启用,raw/worker 不启用
# $env:LOGS_NOFILTER='1' 可禁用过滤 (debug 时看完整内容)
function _Logs-Filter {
  param([Parameter(ValueFromPipeline)]$Line)
  process {
    if ($env:LOGS_NOFILTER -eq '1') { $Line }
    elseif ($Line -notmatch '^\{') { $Line }
  }
}

function Logs-Follow([string]$Agent, [string]$Kind = 'pretty') {
  if ($Agent -eq 'both' -or $Agent -eq 'all') {
    $be = Get-LogPath 'backend' 'pretty'
    $fe = Get-LogPath 'frontend' 'pretty'
    if (-not (Test-Path $be)) { New-Item -ItemType File -Path $be -Force | Out-Null }
    if (-not (Test-Path $fe)) { New-Item -ItemType File -Path $fe -Force | Out-Null }
    Write-Host "follow $be + $fe (Ctrl+C 退出, 默认过滤 JSON; \$env:LOGS_NOFILTER=1 看完整)"
    $j1 = Start-Job -ScriptBlock {
      param($p, $noFilter)
      Get-Content -Path $p -Wait -Tail 50 -Encoding UTF8 | ForEach-Object {
        if ($noFilter -eq '1' -or $_ -notmatch '^\{') { "[BE] $_" }
      }
    } -ArgumentList $be, $env:LOGS_NOFILTER
    $j2 = Start-Job -ScriptBlock {
      param($p, $noFilter)
      Get-Content -Path $p -Wait -Tail 50 -Encoding UTF8 | ForEach-Object {
        if ($noFilter -eq '1' -or $_ -notmatch '^\{') { "[FE] $_" }
      }
    } -ArgumentList $fe, $env:LOGS_NOFILTER
    try {
      while ($true) { Receive-Job -Job $j1, $j2 | Write-Host; Start-Sleep -Milliseconds 200 }
    } finally {
      Stop-Job $j1, $j2 -ErrorAction SilentlyContinue
      Remove-Job $j1, $j2 -ErrorAction SilentlyContinue
    }
    return
  }
  if ($Agent -notin @('backend', 'frontend')) {
    Write-Host "用法: agentctl.ps1 logs {backend|frontend|both} [pretty|worker|raw]"
    exit 2
  }
  $f = Get-LogPath $Agent $Kind
  if (-not $f) {
    Write-Host "kind 必须是 pretty|worker|raw,得到: $Kind"
    exit 2
  }
  if (-not (Test-Path $f)) {
    Write-Host "日志暂不存在,等待第一次写入 ($f)..."
    New-Item -ItemType File -Path $f -Force | Out-Null
  }
  if ($Kind -eq 'pretty') {
    Write-Host "follow $f (Ctrl+C 退出, 默认过滤 JSON; \$env:LOGS_NOFILTER=1 看完整)"
    Get-Content -Path $f -Wait -Tail 50 -Encoding UTF8 | _Logs-Filter
  } else {
    Write-Host "follow $f (Ctrl+C 退出, kind=$Kind 不过滤)"
    Get-Content -Path $f -Wait -Tail 50 -Encoding UTF8
  }
}

# Change 7: Bottom dispatch table
switch ($Command) {
  "up"       { Watchers-Up }
  "start"    { Watchers-Up }
  "down"     { Watchers-Down }
  "stop"     { Watchers-Down }
  "restart"  { Watchers-Down; Start-Sleep -Milliseconds 500; Watchers-Up }
  "logs"     {
    if ($PSBoundParameters.ContainsKey('Target')) { Logs-Follow $Target $LogKind }
    else { Logs-Snapshot }
  }
  "status"   { Show-Status }
  "dispatch" { Dispatch-Agent $Target $Provider $Timeout }
  "wait"     { Wait-Agent $Target $WaitSeconds }
  "watch"    { Watch-Agent $Target }
  "memory"   { Add-Memory $Target }
  "cost"     {
    # v3.6: cost/doctor 复杂聚合逻辑只在 bash 版实现 — Git Bash 必装(kit 依赖), 直接转发
    bash "$PSScriptRoot/agentctl.sh" cost
  }
  "doctor"   {
    bash "$PSScriptRoot/agentctl.sh" doctor
  }
  "release-without-verify" { Release-WithoutVerify $Target $Reason }
}
