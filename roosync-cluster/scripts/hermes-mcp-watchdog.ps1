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

# --- Decision: restart if bridges are missing AND proxy is reachable ---
Write-Log "Proxy reachable, missing $($missingBridges.Count) bridge(s), $errorCount MCP errors in ${LogWindowMinutes}min. Restarting." "ERROR"

docker restart $ContainerName
if ($LASTEXITCODE -eq 0) {
    Write-Log "Container '$ContainerName' restarted successfully. Bridges should reconnect within 30s." "INFO"
}
else {
    Write-Log "Failed to restart container '$ContainerName'." "ERROR"
}
