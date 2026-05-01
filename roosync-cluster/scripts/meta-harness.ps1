<#
.SYNOPSIS
    Meta-Harness Phase 1 — Self-evaluation on scheduler outputs.

.DESCRIPTION
    Analyzes recent scheduler task outputs to extract performance metrics.
    Phase 1 skeleton: success rate, cycle times, error patterns.

    Reads RooSync dashboards for [DONE]/[BLOCKED]/[ERROR] tags and
    produces a summary of agent performance over a time window.

.PARAMETER SharedStatePath
    Path to RooSync shared state dashboards directory.

.PARAMETER Hours
    Time window in hours (default: 24).

.PARAMETER OutputFile
    Optional file path to write the report.

.PARAMETER Quiet
    Only output the report, no progress messages.

.EXAMPLE
    .\meta-harness.ps1
    .\meta-harness.ps1 -Hours 48 -OutputFile report.md
#>
param(
    [string]$SharedStatePath = "G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards",
    [int]$Hours = 24,
    [string]$OutputFile = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SharedStatePath)) {
    Write-Error "Dashboard path not found: $SharedStatePath"
    exit 1
}

if (-not $Quiet) { Write-Host "META-HARNESS Phase 1 | $(Get-Date -Format 'o') | Window: ${Hours}h" }

$cutoff = (Get-Date).AddHours(-$Hours).ToString("yyyy-MM-ddTHH:mm:ss")

# ── Collect workspace dashboards ──────────────────────────────────────
$workspaceFiles = Get-ChildItem -Path $SharedStatePath -Filter "workspace-*.md" -File

# ── Parse messages ────────────────────────────────────────────────────
function Get-IntercomMessages {
    param([string]$Content, [string]$Cutoff)

    $messages = @()
    # Header format: ### [2026-05-01T14:22:53.488Z] machine|workspace
    $pattern = '(?s)### \[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})[^\]]*\]\s*([^\n]*)\n(.+?)(?=\n### \[|\z)'
    $matches = [regex]::Matches($Content, $pattern)

    foreach ($m in $matches) {
        $timestamp = $m.Groups[1].Value
        if ($timestamp -ge $Cutoff) {
            $headerLine = $m.Groups[2].Value.Trim()
            $body = $m.Groups[3].Value.Trim()

            # Extract author from header (format: machine|workspace)
            $author = ""
            if ($headerLine -match '^([a-zA-Z0-9-]+)\|') {
                $author = $Matches[1]
            }

            # Extract tags from ## [TAG] patterns in body (e.g., "## [DONE]", "## [ERROR]")
            $tag = ""
            if ($body -match '## \[([A-Z]+)\]') {
                $tag = $Matches[1]
            }
            # Fallback: check for [TAG] in first line
            if (-not $tag -and $body -match '^\[([A-Z-]+)\]') {
                $tag = $Matches[1]
            }

            $messages += @{
                Timestamp = $timestamp
                Tag       = $tag
                Author    = $author
                Body      = $body.Substring(0, [math]::Min(200, $body.Length))
            }
        }
    }
    return $messages
}

# ── Analyze all workspaces ────────────────────────────────────────────
$allMessages = @()
$workspaceStats = @()

foreach ($f in $workspaceFiles) {
    $wsName = [System.IO.Path]::GetFileNameWithoutExtension($f.FullName) -replace '^workspace-', ''
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $msgs = Get-IntercomMessages -Content $content -Cutoff $cutoff

    $done = ($msgs | Where-Object { $_.Tag -eq 'DONE' }).Count
    $blocked = ($msgs | Where-Object { $_.Tag -eq 'BLOCKED' }).Count
    $error = ($msgs | Where-Object { $_.Tag -eq 'ERROR' }).Count
    $ask = ($msgs | Where-Object { $_.Tag -eq 'ASK' }).Count
    $total = $msgs.Count

    if ($total -gt 0) {
        $workspaceStats += @{
            Workspace   = $wsName
            Total       = $total
            Done        = $done
            Blocked     = $blocked
            Error       = $error
            Ask         = $ask
            SuccessRate = if ($done + $blocked + $error -gt 0) { [math]::Round(($done / ($done + $blocked + $error)) * 100, 1) } else { 0 }
        }
        $allMessages += $msgs
    }
}

# ── Compute aggregate metrics ─────────────────────────────────────────
$totalDone = ($workspaceStats | Measure-Object -Property Done -Sum).Sum
$totalBlocked = ($workspaceStats | Measure-Object -Property Blocked -Sum).Sum
$totalError = ($workspaceStats | Measure-Object -Property Error -Sum).Sum
$totalAsk = ($workspaceStats | Measure-Object -Property Ask -Sum).Sum
$totalMessages = ($workspaceStats | Measure-Object -Property Total -Sum).Sum
$overallRate = if ($totalDone + $totalBlocked + $totalError -gt 0) {
    [math]::Round(($totalDone / ($totalDone + $totalBlocked + $totalError)) * 100, 1)
} else { 0 }

# ── Generate report ───────────────────────────────────────────────────
$timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
$rows = $workspaceStats | Sort-Object Total -Descending | ForEach-Object {
    "| $($_.Workspace) | $($_.Total) | $($_.Done) | $($_.Blocked) | $($_.Error) | $($_.Ask) | $($_.SuccessRate)% |"
}

$report = @"
## [META-HARNESS] — $timestamp
**Window:** ${Hours}h | **Cutoff:** $cutoff

### Aggregate
- **Total messages:** $totalMessages
- **Done:** $totalDone | **Blocked:** $totalBlocked | **Error:** $totalError | **Ask:** $totalAsk
- **Overall success rate:** $overallRate%

### Per-Workspace Breakdown
| Workspace | Messages | Done | Blocked | Error | Ask | Success |
|-----------|----------|------|---------|-------|-----|---------|
$($rows -join "`n")

### Top Errors
$(if ($totalError -eq 0) { "No errors in window." } else {
    $errorMsgs = $allMessages | Where-Object { $_.Tag -eq 'ERROR' } | Select-Object -First 5
    $errorMsgs | ForEach-Object { "- [$($_.Timestamp)] $($_.Body.Substring(0, [math]::Min(120, $_.Body.Length)))..." }
})

### Phase 1 Notes
- This is a skeleton analysis. Future phases: cycle time tracking, anomaly detection, agent-specific metrics.
- Data source: RooSync workspace dashboards (intercom section only).
"@

# ── Output ────────────────────────────────────────────────────────────
if ($OutputFile) {
    [System.IO.File]::WriteAllText($OutputFile, $report, [System.Text.UTF8Encoding]::new($false))
    if (-not $Quiet) { Write-Host "Report written to $OutputFile" }
} else {
    Write-Output $report
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Summary: $($workspaceStats.Count) workspaces, $totalDone done, $totalBlocked blocked, $totalError errors (${overallRate}% success)"
}
