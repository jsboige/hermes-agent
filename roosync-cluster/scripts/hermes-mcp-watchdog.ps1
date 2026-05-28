<#
.SYNOPSIS
    Hermes MCP bridge watchdog — recovers from transient MCP connection loss.

.DESCRIPTION
    Checks that all 3 expected MCP bridges (roo-state-manager, sk-agent, searxng)
    are running inside the Hermes container. If any bridge is missing and the upstream
    proxy is reachable, triggers recovery in escalating stages:

      Stage 1: SIGUSR1 to gateway process (graceful restart, preserves container)
      Stage 2: docker restart (full container restart, last resort)

    Includes exponential backoff to prevent restart loops (incident 2026-05-11:
    10+ restarts in 4 hours because consecutive threshold was too low).

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
    [string]$StateFile = "$PSScriptRoot\..\logs\mcp-watchdog-state.json",
    # New params for exponential backoff
    [int]$MaxConsecutiveFailures = 10,
    [int]$MaxBackoffMinutes = 60
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

function Get-State {
    if (Test-Path $StateFile) {
        try {
            return Get-Content $StateFile -Raw | ConvertFrom-Json
        }
        catch { }
    }
    return @{ ConsecutiveFailures = 0; LastRecovery = $null; LastFailure = $null }
}

function Set-State {
    param([hashtable]$State)
    $State | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
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
    # Reset failure counter on healthy state
    Set-State @{ ConsecutiveFailures = 0; LastRecovery = (Get-State).LastRecovery; LastFailure = $null }
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

# --- Check 4: Container age — skip if recently started ---
$startedAtRaw = docker inspect --format='{{.State.StartedAt}}' $ContainerName 2>$null
if ($LASTEXITCODE -eq 0 -and $startedAtRaw) {
    $startedAtStr = $startedAtRaw -replace '\.\d+Z$', 'Z'
    $startedAt = [DateTimeOffset]::Parse($startedAtStr).UtcDateTime
    $containerAge = ((Get-Date).ToUniversalTime() - $startedAt).TotalMinutes
    if ($containerAge -lt $ContainerAgeThresholdMinutes) {
        Write-Log "Container started $($containerAge.ToString('F1'))min ago (< ${ContainerAgeThresholdMinutes}min threshold). Bridges still connecting — skipping." "WARN"
        exit 0
    }
}

# --- Check 5: Exponential backoff — don't hammer restarts ---
$state = Get-State
$consecutiveFailures = [int]$state.ConsecutiveFailures
$lastRecovery = $state.LastRecovery

# Calculate backoff: 5, 10, 15, 20, ..., up to MaxBackoffMinutes
$backoffMinutes = [Math]::Min(($consecutiveFailures + 1) * 5, $MaxBackoffMinutes)

if ($lastRecovery) {
    try {
        $lastRecoveryTime = [DateTimeOffset]::Parse($lastRecovery).UtcDateTime
        $timeSinceRecovery = ((Get-Date).ToUniversalTime() - $lastRecoveryTime).TotalMinutes
        if ($timeSinceRecovery -lt $backoffMinutes) {
            Write-Log "Backoff active: ${backoffMinutes}min required, only $($timeSinceRecovery.ToString('F1'))min since last recovery. Waiting." "WARN"
            Set-State @{
                ConsecutiveFailures = ($consecutiveFailures + 1)
                LastRecovery        = $lastRecovery
                LastFailure         = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            }
            exit 0
        }
    }
    catch { }
}

# Hard limit: stop trying after MaxConsecutiveFailures
if ($consecutiveFailures -ge $MaxConsecutiveFailures) {
    Write-Log "Max consecutive failures ($MaxConsecutiveFailures) reached. Giving up until next healthy check resets counter." "ERROR"
    exit 0
}

# --- Recovery Stage 1: SIGUSR1 to gateway process ---
$recovered = $false

# Find the gateway PID
$gatewayPid = $null
$gatewayProc = docker exec $ContainerName ps aux 2>$null | Select-String "hermes gateway run"
if ($gatewayProc -and $gatewayProc -match '^\S+\s+(\d+)') {
    $gatewayPid = $Matches[1]
}

if ($gatewayPid) {
    Write-Log "Stage 1: Sending SIGUSR1 to gateway PID $gatewayPid (graceful restart)." "INFO"
    docker exec $ContainerName kill -SIGUSR1 $gatewayPid 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SIGUSR1 sent. Gateway will restart in-place (no container reboot)." "INFO"
        $recovered = $true
    }
    else {
        Write-Log "SIGUSR1 failed. Escalating to Stage 2." "WARN"
    }
}

# --- Recovery Stage 2: docker restart (last resort) ---
if (-not $recovered) {
    Write-Log "Stage 2: docker restart '$ContainerName' (full container reboot)." "ERROR"
    docker restart $ContainerName
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Container '$ContainerName' restarted successfully." "INFO"
        $recovered = $true
    }
    else {
        Write-Log "Failed to restart container '$ContainerName'." "ERROR"
    }
}

# Update state
Set-State @{
    ConsecutiveFailures = ($consecutiveFailures + 1)
    LastRecovery        = if ($recovered) { Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' } else { $lastRecovery }
    LastFailure         = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
}
