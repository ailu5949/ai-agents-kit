# ai-agents-kit v3.1: 桌面通知层 — 主 Claude 离线时也能让 Lane 知道任务变化。
#
# 调用约定:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File notify-toast.ps1 `
#     -Agent backend -Status done -Message "...optional..." -Project choseStock
#
# 实现策略:
#   1. 优先用 BurntToast(漂亮 Toast + ActionCenter 留底), 没装则
#   2. 兜底用 System.Windows.Forms.NotifyIcon BalloonTip(Win10/11 原生, 零依赖)
#   3. 都失败静默退出, 不影响主流程
#
# 设计要点:
#   - Windows-only(macOS/Linux 静默 exit 0)
#   - 8 秒气泡 + 异常静默, 必须 background spawn 不能阻塞 agent-runner
#   - 标题含 emoji + project + agent + status, Lane 一眼定位
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('backend', 'frontend')][string]$Agent,
    [Parameter(Mandatory = $true)][string]$Status,
    [string]$Message = '',
    [string]$Project = ''
)

$ErrorActionPreference = 'SilentlyContinue'

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    exit 0
}

$emoji = switch ($Status) {
    'done'             { 'OK' }
    'done-awaiting-review' { 'OK' }
    'stale'            { 'OK' }
    'ready-for-human'  { 'GO' }
    'failed'           { 'X'  }
    'timeout'          { 'TO' }
    default            { '..' }
}

$balloonIcon = switch ($Status) {
    'failed'  { 'Error' }
    'timeout' { 'Warning' }
    default   { 'Info' }
}

$projectTag = if ($Project) { "[$Project] " } else { '' }
$title = "${projectTag}${Agent} ${Status}".Trim()
if ($emoji) { $title = "$emoji $title" }

$bodyLines = @()
if ($Message) { $bodyLines += $Message }
switch ($Status) {
    'done'                  { $bodyLines += '回到 Claude Code 审查 (Karpathy 6 项)' }
    'done-awaiting-review'  { $bodyLines += '回到 Claude Code 审查 (Karpathy 6 项)' }
    'stale'                 { $bodyLines += 'work 已落, 回 Claude Code 代 commit + 审查' }
    'ready-for-human'       { $bodyLines += 'verify gate 全过, Lane 拍板' }
    'failed'                { $bodyLines += '看 events.jsonl 末尾 + log 末尾, 决定修复 / 切 provider' }
    'timeout'               { $bodyLines += '看 stop-notify 注入诊断, 走 Timeout Triage SOP' }
}
$body = ($bodyLines -join "`r`n")

# Layer A: BurntToast (best UX, optional)
$btModule = Get-Module -ListAvailable -Name BurntToast | Select-Object -First 1
if ($btModule) {
    Import-Module BurntToast
    if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
        try {
            $textArr = @($title)
            if ($body) { $textArr += $body }
            New-BurntToastNotification -Text $textArr -AppLogo $null -Silent:$false | Out-Null
            exit 0
        } catch {
            # fall through to NotifyIcon
        }
    }
}

# Layer B: NotifyIcon BalloonTip (Win10/11 native, zero-dep)
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$balloonIcon
    $notify.BalloonTipTitle = $title
    $notify.BalloonTipText = if ($body) { $body } else { ' ' }
    $notify.Visible = $true
    $notify.ShowBalloonTip(8000)
    Start-Sleep -Milliseconds 8500
    $notify.Visible = $false
    $notify.Dispose()
} catch {
    # Both layers failed — silently exit so notification never blocks the runner
}

exit 0
