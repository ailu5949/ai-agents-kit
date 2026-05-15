#requires -Version 5.1
# ai-agents-kit v2 Stop hook (PowerShell 等价物)
$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$root = (& git rev-parse --show-toplevel 2>$null)
if (-not $root) { $root = (Get-Location).Path }
$signalDir = Join-Path $root ".aiagents\signals"
$stateFile = Join-Path $root ".aiagents\state\current.json"
if (-not (Test-Path $signalDir)) { exit 0 }

$events = New-Object System.Collections.Generic.List[string]
foreach ($agent in @("backend", "frontend")) {
  foreach ($suffix in @("done", "failed", "timeout")) {
    $path = Join-Path $signalDir "${agent}_$suffix"
    if (Test-Path $path) {
      $reason = ""
      if ($suffix -ne "done") { $reason = (Get-Content -Raw -Encoding UTF8 $path) }
      $ts = Get-Date -Format "yyyyMMdd_HHmmss"
      Move-Item -Force $path (Join-Path $signalDir ".consumed_${agent}_${suffix}_$ts")
      switch ($suffix) {
        "done"    { $events.Add("- ✅ $agent 开发完成,请立即审查") }
        "failed"  { $events.Add("- ❌ $agent 开发失败: $reason") }
        "timeout" { $events.Add("- ⏰ $agent 编码 agent 超时(可能网络卡死): $reason") }
      }
    }
  }
}

if ($events.Count -eq 0) { exit 0 }

$stateExcerpt = ""
if (Test-Path $stateFile) {
  try { $stateExcerpt = (Get-Content -Raw -Encoding UTF8 $stateFile).Substring(0, [Math]::Min(2000, (Get-Item $stateFile).Length)) } catch {}
}

$body = @"
[Stop hook] 检测到 编码 agent 状态变化(wait 命令未消费时由此兜底):
$($events -join "`n")

权威状态参考(.aiagents/state/current.json 摘录):
$stateExcerpt

注意:
- signal 只是触发器;state.<agent>.state == "done-awaiting-review" 才是审查依据
- 如果 wait 命令已经处理过对应信号,忽略本条即可

按 CLAUDE.md 的 Karpathy 审查 rubric 处理:
1. 读 .aiagents/logs/{be|fe}_<date>.log 最新尾部 + .aiagents/state/events.jsonl
2. 对项目目录跑 git diff,确认改动落地
3. 对照 docs/ai-agents/specs/02-后端编码.md / 03-前端编码.md 每条验收标准逐项核对
4. 跑测试和 lint(从 .aiagents/config.json 或 .claude/agents.conf 读)
5. 把审查段落追加到 docs/ai-agents/reviews/backend-review.md 或 frontend-review.md
6. 通过则推进下一阶段,失败则生成 docs/ai-agents/specs/04-Bug修复-*.md 并询问是否 /bugfix-*
"@

@{ decision = "block"; reason = $body } | ConvertTo-Json -Compress
