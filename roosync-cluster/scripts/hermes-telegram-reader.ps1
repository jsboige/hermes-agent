<#
.SYNOPSIS
    Retrieve Hermes bot Telegram conversation messages from inside the Docker container.

.DESCRIPTION
    Reads session JSON files from the Hermes container to extract Telegram DM and group chat
    messages. Useful for diagnosing what Hermes sent to users without opening Telegram.

.PARAMETER Chat
    Which chat to read: 'dm', 'group', or 'all' (default: 'all')

.PARAMETER Lines
    Number of most recent messages to display (default: 15)

.PARAMETER Raw
    Show raw JSON output instead of formatted text

.EXAMPLE
    ./hermes-telegram-reader.ps1 -Chat dm -Lines 10
    ./hermes-telegram-reader.ps1 -Chat group
    ./hermes-telegram-reader.ps1 -Chat all -Raw

.NOTES
    Requires Docker access to the 'hermes' container.
    Session files are at /opt/data/sessions/ inside the container.
    sessions.json maps chat keys to session IDs.
#>

param(
    [ValidateSet('dm', 'group', 'all')]
    [string]$Chat = 'all',
    [int]$Lines = 15,
    [switch]$Raw
)

$ContainerName = 'hermes'

function Get-SessionJson {
    param([string]$Path)
    $result = docker exec $ContainerName bash -c "cat $Path" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to read $Path from container: $result"
        return $null
    }
    try {
        return $result | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse JSON from $Path"
        return $null
    }
}

function Show-SessionMessages {
    param(
        [string]$SessionId,
        [string]$ChatLabel,
        [int]$Count
    )

    # Find the session file - could be session_YYYYMMDD_HHMMSS_ID.json or have a different prefix
    $sessionFile = docker exec $ContainerName bash -c "ls -t /opt/data/sessions/*${SessionId}*.json 2>/dev/null | head -1" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sessionFile)) {
        # Try the .jsonl format
        $sessionFile = docker exec $ContainerName bash -c "ls -t /opt/data/sessions/${SessionId}.jsonl 2>/dev/null | head -1" 2>&1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sessionFile)) {
            Write-Warning "[$ChatLabel] Session file not found for ID: $SessionId"
            return
        }
    }

    $sessionFile = $sessionFile.Trim()

    if ($Raw) {
        docker exec $ContainerName bash -c "cat `"$sessionFile`"" 2>&1
        return
    }

    # Extract messages using Python inside the container
    $pythonScript = @"
import json, sys

with open('$sessionFile') as f:
    data = json.load(f)

messages = data.get('messages', [])
# Take last N messages
selected = messages[-$Count:]

for msg in selected:
    role = msg.get('role', '?')
    content = str(msg.get('content', ''))
    # Truncate long tool outputs
    if role == 'tool':
        if len(content) > 200:
            content = content[:200] + '...'
        print(f'  [{role}] {content}')
    else:
        if len(content) > 500:
            content = content[:500] + '...'
        print(f'[{role}] {content}')
    print()
"@

    Write-Host "`n=== $ChatLabel (last $Count messages) ===" -ForegroundColor Cyan
    Write-Host "Session file: $sessionFile`n"

    docker exec $ContainerName bash -c "python3 -c `"$pythonScript`"" 2>&1
}

# Get sessions index
$sessions = Get-SessionJson -Path '/opt/data/sessions/sessions.json'
if (-not $sessions) {
    Write-Error "Cannot read sessions.json from Hermes container"
    exit 1
}

# Map session keys
$sessionMap = @{}
foreach ($prop in $sessions.PSObject.Properties) {
    $key = $prop.Name
    $val = $prop.Value
    $sessionMap[$key] = $val
}

# Find relevant sessions
$dmKey = $sessionMap.Keys | Where-Object { $_ -match 'telegram:dm:' } | Select-Object -First 1
$groupKey = $sessionMap.Keys | Where-Object { $_ -match 'telegram:group:' } | Select-Object -First 1

if ($Chat -eq 'dm' -or $Chat -eq 'all') {
    if ($dmKey -and $sessionMap[$dmKey].session_id) {
        $dmSessionId = $sessionMap[$dmKey].session_id
        $dmName = $sessionMap[$dmKey].display_name
        Show-SessionMessages -SessionId $dmSessionId -ChatLabel "DM ($dmName)" -Count $Lines
    }
    else {
        Write-Warning "No DM session found"
    }
}

if ($Chat -eq 'group' -or $Chat -eq 'all') {
    if ($groupKey -and $sessionMap[$groupKey].session_id) {
        $groupSessionId = $sessionMap[$groupKey].session_id
        $groupName = $sessionMap[$groupKey].display_name
        $resumePending = $sessionMap[$groupKey].resume_pending
        Show-SessionMessages -SessionId $groupSessionId -ChatLabel "Group ($groupName)" -Count $Lines
        if ($resumePending) {
            Write-Host "`n  [!] Group session has resume_pending=true (interrupted by restart)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Warning "No group chat session found"
    }
}

# Show sessions summary
Write-Host "`n=== Active Telegram Sessions ===" -ForegroundColor Cyan
foreach ($key in $sessionMap.Keys) {
    $s = $sessionMap[$key]
    $platform = $s.origin.platform
    $chatType = $s.origin.chat_type
    $chatName = $s.display_name
    $sessionId = $s.session_id
    $updatedAt = $s.updated_at
    $suspended = $s.suspended
    $resumePending = $s.resume_pending

    $status = if ($suspended) { "SUSPENDED" } elseif ($resumePending) { "RESUME_PENDING" } else { "ACTIVE" }
    Write-Host "  [$status] $chatType ($chatName) - session $sessionId - updated $updatedAt"
}

# Also show cron sessions (most recent)
Write-Host "`n=== Recent Cron Sessions ===" -ForegroundColor Cyan
$cronSessions = docker exec $ContainerName bash -c "ls -t /opt/data/sessions/session_cron_*.json 2>/dev/null | head -5" 2>&1
if ($cronSessions) {
    $cronSessions -split "`n" | ForEach-Object {
        $file = $_.Trim()
        if ($file) {
            $name = Split-Path $file -Leaf
            Write-Host "  $name"
        }
    }
}
