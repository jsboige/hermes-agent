<#
.SYNOPSIS
    Hermes Cluster Monitor — Reads all dashboards and produces a health report.

.DESCRIPTION
    Periodic health audit across all RooSync dashboards. Identifies stale
    workspaces, approaching condensation thresholds, missing heartbeats,
    and cross-workspace anomalies.

    Output: Markdown health report to stdout (for Claude Code to post).

.PARAMETER SharedStatePath
    Path to RooSync shared state dashboards directory.

.PARAMETER OutputFile
    Optional file path to write the report.

.PARAMETER Quiet
    Only output the report, no progress messages.

.EXAMPLE
    .\cluster-monitor.ps1
    .\cluster-monitor.ps1 -OutputFile report.md
#>
param(
    [string]$SharedStatePath = "G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards",
    [string]$OutputFile = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SharedStatePath)) {
    Write-Error "Dashboard path not found: $SharedStatePath"
    exit 1
}

if (-not $Quiet) { Write-Host "HERMES CLUSTER-MONITOR | $(Get-Date -Format 'o')" }

# ── Collect dashboard files ──────────────────────────────────────────
$dashboardFiles = Get-ChildItem -Path $SharedStatePath -Filter "*.md" -File
if (-not $Quiet) { Write-Host "Found $($dashboardFiles.Count) dashboards" }

# ── Parse dashboard metadata ─────────────────────────────────────────
function Get-DashboardInfo {
    param([string]$FilePath)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $size = $content.Length

    # Extract type from name pattern
    $type = "unknown"
    if ($name -eq "global") { $type = "global" }
    elseif ($name -match "^workspace-(.+)$") { $type = "workspace"; $workspaceId = $Matches[1] }
    elseif ($name -match "^machine-(.+)$") { $type = "machine"; $machineId = $Matches[1] }

    # Count intercom messages (### [timestamp] pattern)
    $msgCount = ([regex]::Matches($content, "^### \[", [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count

    # Find last activity timestamp
    $lastActivity = $null
    $timeMatches = [regex]::Matches($content, "### \[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($timeMatches.Count -gt 0) {
        $lastActivity = $timeMatches[$timeMatches.Count - 1].Groups[1].Value
    }

    # Utilization
    $utilPct = [math]::Round(($size / 51200) * 100, 1)

    # Extract status section
    $statusSection = ""
    if ($content -match "(?s)## Status\s*\n(.+?)(?=\n## |\z)") {
        $statusSection = $Matches[1].Trim()
    }

    return @{
        Name         = $name
        Type         = $type
        WorkspaceId  = if ($type -eq "workspace") { $workspaceId } else { "" }
        MachineId    = if ($type -eq "machine") { $machineId } else { "" }
        Size         = $size
        Utilization  = $utilPct
        MessageCount = $msgCount
        LastActivity = $lastActivity
        Status       = $statusSection
    }
}

# ── Parse all dashboards ─────────────────────────────────────────────
$dashboards = @()
$workspaceDashboards = @()
$machineDashboards = @()
$globalDashboard = $null

foreach ($f in $dashboardFiles) {
    $info = Get-DashboardInfo -FilePath $f.FullName
    $dashboards += $info
    switch ($info.Type) {
        "workspace" { $workspaceDashboards += $info }
        "machine" { $machineDashboards += $info }
        "global" { $globalDashboard = $info }
    }
}

# ── Compute health metrics ───────────────────────────────────────────
$now = Get-Date
$alerts = @()

# Workspace health
$workspaceRows = @()
foreach ($ws in $workspaceDashboards | Sort-Object Utilization -Descending) {
    $staleHours = $null
    $statusIcon = "OK"
    if ($ws.LastActivity) {
        $lastDate = [datetime]::Parse($ws.LastActivity)
        $staleHours = [math]::Round(($now - $lastDate).TotalHours, 1)
        if ($staleHours -gt 48) { $statusIcon = "STALE" }
        elseif ($staleHours -gt 24) { $statusIcon = "SLOW" }
    } else {
        $statusIcon = "EMPTY"
    }

    if ($ws.Utilization -gt 90) {
        $alerts += "CRITICAL: $($ws.WorkspaceId) at $($ws.Utilization)% — condensation imminent"
        $statusIcon = "ALERT"
    } elseif ($ws.Utilization -gt 80) {
        $alerts += "WARNING: $($ws.WorkspaceId) at $($ws.Utilization)% — approaching condensation"
        $statusIcon = "WARN"
    }

    $workspaceRows += "| $($ws.WorkspaceId) | $($ws.Utilization)% | $(if ($ws.LastActivity) { $ws.LastActivity } else { 'never' }) | $($ws.MessageCount) | $statusIcon |"
}

# Machine health
$machineRows = @()
$knownMachines = @("myia-ai-01", "myia-po-2023", "myia-po-2024", "myia-po-2025", "myia-po-2026", "myia-web1", "nanoclaw-cluster", "web1")
$reportingMachines = @()

foreach ($m in $machineDashboards) {
    $reportingMachines += $m.MachineId
    $staleHours = $null
    $statusIcon = "ONLINE"
    if ($m.LastActivity) {
        $lastDate = [datetime]::Parse($m.LastActivity)
        $staleHours = [math]::Round(($now - $lastDate).TotalHours, 1)
        if ($staleHours -gt 2) { $statusIcon = "OFFLINE" }
        elseif ($staleHours -gt 1) { $statusIcon = "STALE" }
    }

    if ($statusIcon -eq "OFFLINE") {
        $alerts += "OFFLINE: $($m.MachineId) — no heartbeat for ${staleHours}h"
    }

    $machineRows += "| $($m.MachineId) | $(if ($m.LastActivity) { $m.LastActivity } else { 'never' }) | $statusIcon |"
}

# Missing machines
foreach ($known in $knownMachines) {
    if ($known -notin $reportingMachines) {
        $machineRows += "| $known | missing | NO-DASHBOARD |"
        $alerts += "MISSING: $known has no machine dashboard"
    }
}

# ── Generate report ──────────────────────────────────────────────────
$timestamp = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
$report = @"
## [CLUSTER-HEALTH] — $timestamp

### Cluster Summary
| Workspace | Utilization | Last Activity | Messages | Status |
|-----------|-------------|---------------|----------|--------|
$($workspaceRows -join "`n")

### Machine Health
| Machine | Last Heartbeat | Status |
|---------|---------------|--------|
$($machineRows -join "`n")

### Alerts
$(if ($alerts.Count -eq 0) { "None" } else { $alerts | ForEach-Object { "- $_" } })

### Stats
- Total dashboards: $($dashboards.Count)
- Workspace dashboards: $($workspaceDashboards.Count)
- Machine dashboards: $($machineDashboards.Count)
- Alerts: $($alerts.Count)
- Scan time: $timestamp
"@

# ── Output ───────────────────────────────────────────────────────────
if ($OutputFile) {
    [System.IO.File]::WriteAllText($OutputFile, $report, [System.Text.UTF8Encoding]::new($false))
    if (-not $Quiet) { Write-Host "Report written to $OutputFile" }
} else {
    Write-Output $report
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Summary: $($workspaceDashboards.Count) workspaces, $($machineDashboards.Count) machines, $($alerts.Count) alerts"
}
