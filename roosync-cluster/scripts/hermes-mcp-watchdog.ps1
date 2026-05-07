<#
.SYNOPSIS
    Hermes MCP bridge watchdog — restarts the container when mcp-remote is stuck.

.DESCRIPTION
    Probes the Hermes container health and the MCP proxy endpoint from the host.
    If the MCP proxy is reachable but Hermes reports persistent MCP failures in
    its logs, restarts the container to force mcp-remote reconnection.

    This is a safety net for cases where the in-process circuit breaker
    auto-reconnect (in mcp_tool.py) doesn't recover the connection.

.NOTES
    Deploy as a Windows Scheduled Task on po-2026:
    - Trigger: every 15 minutes
    - Action: powershell -File "C:\path\to\hermes-mcp-watchdog.ps1"
    - Run whether user is logged on or not

    Author: Hermes Agent workspace
    Issue: #2012 — MCP proxy SPOF: Qdrant drift cascades to total MCP loss
#>

param(
    [string]$ContainerName = "hermes",
    [int]$McpErrorThreshold = 5,
    [int]$LogWindowMinutes = 15,
    [string]$LogPath = "$PSScriptRoot\..\logs\mcp-watchdog.log"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Output $entry
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
}

# --- Check 1: Container running ---
$containerStatus = docker inspect --format='{{.State.Status}}' $ContainerName 2>$null
if ($LASTEXITCODE -ne 0 -or $containerStatus -ne "running") {
    Write-Log "Container '$ContainerName' is not running (status: $containerStatus). Skipping." "WARN"
    exit 0
}

# --- Check 2: Gateway health endpoint ---
try {
    $healthResponse = Invoke-WebRequest -Uri "http://localhost:8642/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    if ($healthResponse.StatusCode -ne 200) {
        Write-Log "Gateway health check returned status $($healthResponse.StatusCode)" "WARN"
    }
}
catch {
    Write-Log "Gateway health endpoint unreachable: $($_.Exception.Message)" "WARN"
}

# --- Check 3: MCP proxy endpoint reachability ---
$mcpReachable = $false
try {
    $null = Invoke-WebRequest -Uri "https://mcp-tools.myia.io/roo-state-manager/mcp" `
        -Method POST -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    $mcpReachable = $true
}
catch {
    # 401 = endpoint alive but needs auth (healthy)
    # 4xx = endpoint alive (healthy)
    # Timeout/connection error = endpoint down
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        if ($statusCode -ge 400 -and $statusCode -lt 500) {
            $mcpReachable = $true
        }
    }
}

if (-not $mcpReachable) {
    Write-Log "MCP proxy endpoint unreachable. Upstream issue — not restarting container." "WARN"
    exit 0
}

# --- Check 4: Container logs for MCP errors ---
$since = (Get-Date).AddMinutes(-$LogWindowMinutes).ToString("yyyy-MM-ddTHH:mm:ss")
try {
    $logs = docker logs $ContainerName --since $since --tail 200 2>&1
}
catch {
    Write-Log "Failed to read container logs: $($_.Exception.Message)" "WARN"
    exit 0
}

$mcpErrors = ($logs | Where-Object {
    $_ -match "MCP.*(fail|error|unreachable|Missing session|ClosedResource)" -and
    $_ -notmatch "circuit breaker opened.*triggering reconnect"
})

$errorCount = ($mcpErrors | Measure-Object).Count

if ($errorCount -ge $McpErrorThreshold) {
    Write-Log "MCP error threshold reached ($errorCount >= $McpErrorThreshold in last ${LogWindowMinutes}min). Restarting container." "ERROR"

    docker restart $ContainerName
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Container '$ContainerName' restarted successfully." "INFO"
    }
    else {
        Write-Log "Failed to restart container '$ContainerName'." "ERROR"
    }
}
else {
    Write-Log "MCP health OK ($errorCount errors in last ${LogWindowMinutes}min, threshold: $McpErrorThreshold)." "DEBUG"
}
