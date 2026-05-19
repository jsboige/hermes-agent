<#
.SYNOPSIS
    Hermes MCP bridge watchdog — restarts the container when mcp-remote bridges are missing.

.DESCRIPTION
    Checks that all 3 expected MCP bridges (roo-state-manager, sk-agent, searxng)
    are running inside the Hermes container. If any bridge is missing and the upstream
    proxy is reachable, restarts the container.

    Also checks for persistent MCP errors in container logs as a secondary signal.

.NOTES
    Deploy as a Windows Scheduled Task on po-2026:
    - Trigger: every 15 minutes
    - Action: powershell -File "C:\dev\hermes-agent\roosync-cluster\scripts\hermes-mcp-watchdog.ps1"
    - Run whether user is logged on or not

    Author: Hermes Agent workspace
    Issue: #2012 — MCP proxy SPOF: Qdrant drift cascades to total MCP loss
#>

param(
    [string]$ContainerName = "hermes",
    [int]$ExpectedBridges = 3,
    [int]$McpErrorThreshold = 5,
    [int]$LogWindowMinutes = 15,
    [string]$McpProxyUrl = "http://192.168.0.47:9090/roo-state-manager/mcp",
    [string]$LogPath = "$PSScriptRoot\..\logs\mcp-watchdog.log",
    [int]$ContainerAgeThresholdMinutes = 5,
    [int]$ConsecutiveFailThreshold = 3,
    [string]$StateFile = "$PSScriptRoot\..\logs\mcp-watchdog-state.json"
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

# --- Check 2: Count active mcp-remote bridges ---
$bridgeCount = 0
$missingBridges = @()
foreach ($name in @("roo-state-manager", "sk-agent", "searxng")) {
    $procLine = docker exec $ContainerName ps aux 2>$null | Select-String "mcp-remote.*$name"
    if ($procLine) {
        $bridgeCount++
    }
    else {
        $missingBridges += $name
    }
}

if ($bridgeCount -eq $ExpectedBridges) {
    Write-Log "All $ExpectedBridges MCP bridges active." "DEBUG"
    # Reset consecutive failure counter when healthy
    if (Test-Path $StateFile) {
        @{ ConsecutiveFailures = 0; LastCheck = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
    }
    exit 0
}

Write-Log "Missing bridges: $($missingBridges -join ', ') ($bridgeCount/$ExpectedBridges active)." "WARN"

# --- Check 3: Is the upstream proxy reachable? ---
$proxyReachable = $false
try {
    $null = Invoke-WebRequest -Uri $McpProxyUrl -Method POST -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    $proxyReachable = $true
}
catch {
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        # 401/403/404 = proxy is alive (backend may not be registered yet)
        if ($statusCode -ge 400 -and $statusCode -lt 500) {
            $proxyReachable = $true
        }
    }
}

if (-not $proxyReachable) {
    Write-Log "MCP proxy unreachable ($McpProxyUrl). Upstream issue — not restarting." "WARN"
    exit 0
}

# --- Check 4: Persistent MCP errors in logs (secondary signal) ---
$since = (Get-Date).AddMinutes(-$LogWindowMinutes).ToString("yyyy-MM-ddTHH:mm:ss")
try {
    $logs = docker logs $ContainerName --since $since --tail 200 2>&1
}
catch {
    Write-Log "Failed to read container logs: $($_.Exception.Message)" "WARN"
}

$mcpErrors = ($logs | Where-Object {
    $_ -match "MCP.*(fail|error|unreachable|Missing session|ClosedResource|Fatal error)" -and
    $_ -notmatch "circuit breaker opened.*triggering reconnect"
})
$errorCount = ($mcpErrors | Measure-Object).Count

# --- Check 5: Container age — skip if recently started (bridges still connecting) ---
$startedAtRaw = docker inspect --format='{{.State.StartedAt}}' $ContainerName 2>$null
if ($LASTEXITCODE -eq 0 -and $startedAtRaw) {
    # Parse ISO 8601 timestamp (Docker returns nanosecond precision)
    $startedAtStr = $startedAtRaw -replace '\.\d+Z$', 'Z'
    $startedAt = [DateTimeOffset]::Parse($startedAtStr).UtcDateTime
    $containerAge = ((Get-Date).ToUniversalTime() - $startedAt).TotalMinutes
    if ($containerAge -lt $ContainerAgeThresholdMinutes) {
        Write-Log "Container started $($containerAge.ToString('F1'))min ago (< ${ContainerAgeThresholdMinutes}min threshold). Bridges still connecting — skipping." "WARN"
        exit 0
    }
}

# --- Check 6: Consecutive failure tracking — require N consecutive failures before restarting ---
$consecutiveFailures = 0
if (Test-Path $StateFile) {
    try {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        $consecutiveFailures = [int]$state.ConsecutiveFailures
    }
    catch { $consecutiveFailures = 0 }
}

$consecutiveFailures++
$stateData = @{ ConsecutiveFailures = $consecutiveFailures; LastCheck = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') }
$stateData | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8

if ($consecutiveFailures -lt $ConsecutiveFailThreshold) {
    Write-Log "Missing $($missingBridges.Count) bridge(s), but only $consecutiveFailures/$ConsecutiveFailThreshold consecutive failures. Waiting." "WARN"
    exit 0
}

# --- Decision: restart only after N consecutive failures, proxy reachable, and container is old enough ---
Write-Log "Proxy reachable, missing $($missingBridges.Count) bridge(s) for $consecutiveFailures consecutive checks, $errorCount MCP errors. Restarting." "ERROR"

docker restart $ContainerName
if ($LASTEXITCODE -eq 0) {
    Write-Log "Container '$ContainerName' restarted successfully. Bridges should reconnect within 30s." "INFO"
    # Reset failure counter on successful restart
    @{ ConsecutiveFailures = 0; LastCheck = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}
else {
    Write-Log "Failed to restart container '$ContainerName'." "ERROR"
}
