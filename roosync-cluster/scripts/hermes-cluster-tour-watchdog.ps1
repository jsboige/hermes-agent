<#
.SYNOPSIS
    Hermes cluster-tour global-post watchdog — detects the silent-skip of ETAPE 3.

.DESCRIPTION
    The cluster-tour cron (schedule "13 */12 * * *", fires ~00:13/12:13 UTC) must
    append a [CLUSTER-HEALTH] post on the GLOBAL dashboard at every fire (prompt
    ETAPE 3, marked OBLIGATOIRE/INCONDITIONNEL). Since 2026-08-12 it silently skips
    that post non-deterministically while reporting status=ok ("completed
    successfully") — 4 consecutive fires post-T#40 without a global post (issue
    jsboige/hermes-agent #3). Prompt-side emphasis reached its limit; a prompt
    cannot close a prompt-skipping defect.

    Post-hoc root cause (2026-08-15, ai-01): the 12→15/08 skips were caused by the
    roo-state-manager backend instance dying behind sparfenyuk — initialize was still
    signed in ~5 ms while every tool call returned isError:true, so processes, ports
    and freshness all stayed green while the dashboard write path was dead (fix:
    MCP-Proxy-RSM Stop+Start + docker restart myia-mcp-proxy, hardened in
    roo-extensions mcp-chain-watchdog.ps1 commit f6580da6). A missing post is a GAP
    regardless of cause: this watchdog flags it, and the operator attributes it by
    cross-referencing bus state (surveillance routine checks 6/8).

    This watchdog is the ai-01-specified "organe" (design validated, 5 points):
      1. separate cron shifted ~15min after each cluster-tour fire; NEVER re-fires
         the tour (verifier, not duplicate);
      2. assertion: a [CLUSTER-HEALTH] append on global carries a timestamp
         POSTERIOR to the start of the watched tour;
      3. if missing — in order: (a) post a [WARN] on global where the post should
         have been, (b) DM ai-01 HIGH (via the visible global [WARN] read by
         cluster MCP agents + Telegram as the urgent channel);
      4. never auto re-fire;
      5. instrument the rate: every check writes its verdict (OK/MISSING) to a
         counter-able state file.

    INDEPENDENT observer: reads from the HOST volume and the shared drive, so it
    keeps working when the Hermes container itself is down (exactly when the gap
    is most likely). Sources:
      - %USERPROFILE%\.hermes\cron\jobs.json   → cluster-tour job fire anchor:
        last_dispatch.dispatched_at (START of the run), fallback last_run_at
      - G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards\global.md
        and the condensation archives written after the fire
        (dashboards\archive\global-<ts>.md) → last [CLUSTER-HEALTH] title

    False positive 2026-09-20 00:37Z (roo-extensions #3743) — DUAL cause, both
    structural, both verified firsthand (watchdog log + global.md + jobs.json):
      a. ANCHOR: last_run_at is the END of the job, but ETAPE 3 executes DURING
         the run — the tour's append is therefore always PRIOR to last_run_at.
         A window anchored on the end time can never contain the post it watches
         (fire 00:14:38.955 = last_run_at, T#112 posted 00:14:09.8, 29 s before).
         Design point 2 below says "POSTERIOR to the START of the watched tour":
         anchoring on last_dispatch.dispatched_at restores exactly that.
      b. TITLE REGEX: the tour title format drifted again — since T#112 the
         append carries tags, rendering "[CLUSTER-HEALTH][DONE] T#112 — ...".
         The strict "\[CLUSTER-HEALTH\]\s+T#N" pattern matched nothing anymore
         (last_health=never in the log since 19/09 23:37Z, after the auto-
         condensation archived the last old-format block T#111), so postOk could
         not be true regardless of the anchor. The title pattern now tolerates
         any number of intercalated bracketed tags.

    Seat port 2026-10-16 (ai-01 interim seat):
      - The [WARN] goes through the RooSync bus (roosync_dashboard append on
        global, MCP over HTTP, the transport of roo-extensions
        mcp-chain-watchdog.ps1) instead of Add-Content on global.md: a direct
        file write skips the PG half of the v3 dashboard store. Author = this
        seat (machine from COMPUTERNAME, workspace hermes-agent); the messageId is
        keyed on the fire, so a retry or a later tick never posts it twice.
      - The tour title is also searched in the archives written after the fire:
        an auto-condensation between the post and the check would otherwise
        archive the block and read as MISSING (the #3743 b. path). Measured
        16/10: T#165 and T#166 live only in archive/global-2026-10-15T*.md.
      - Write-Log writes to the host stream. On the success stream its line was
        captured in the return value of every function that logs before
        returning, so "return $false" came back as a truthy array and
        "return $null" as a non-null one (the defect fixed in
        hermes-review-watchdog.ps1 on 2026-10-15).
      - -DryRun: verdict plus the exact WARN and Telegram text, and one real
        read-only call on the bus route; posts nothing, alerts nothing, writes no
        state.

    Telegram alert goes to the same review chat as hermes-review-watchdog.ps1.
    A cooldown (state file) prevents spam; only a DELIVERED alert starts it.
    Every run logs to cluster-tour-watchdog.log. Dates follow the review-watchdog
    pattern: all timestamps normalized to UTC [datetime] via ConvertTo-UtcDateTime
    (avoids the fr-FR Invoke-RestMethod/culture date bugs).

.NOTES
    Deploy as a Windows Scheduled Task on the seat host:
    - Trigger: every 30 minutes (off-minute, e.g. :07/:37)
    - Action: powershell -NoProfile -File "<repo>\roosync-cluster\scripts\hermes-cluster-tour-watchdog.ps1"
    - Prove it first: -DryRun

    Author: Hermes Agent workspace (operator Claude Code po-2026, seat port ai-01)
    Issue:  jsboige/hermes-agent #3
#>

param(
    [string]$ClusterTourJobId = "",   # empty = the job named *cluster-tour* (ids differ per seat)
    [string]$JobsFile = "$env:USERPROFILE\.hermes\cron\jobs.json",
    [string]$GlobalDashFile = "G:\Mon Drive\Synchronisation\RooSync\.shared-state\dashboards\global.md",
    [string]$HostEnvFile = "$env:USERPROFILE\.hermes\.env",
    [string]$SecretsFile = "$env:USERPROFILE\.hermes\.env.secrets",   # MCP_AUTH_TOKEN (bus bearer)
    [string[]]$RsmUrls = @(
        "http://127.0.0.1:9090/roo-state-manager/mcp",
        "https://mcp-tools.myia.io/roo-state-manager/mcp"
    ),
    [string]$SeatMachineId = "$env:COMPUTERNAME".ToLowerInvariant(),
    [string]$SeatWorkspace = "hermes-agent",
    [int]$BusTimeoutSec = 60,            # an append can take ~45 s when condensation fires
    [string]$ReviewChatId = "-1003904676273",
    [double]$PostMarginMinutes = 15.0,   # how long after a fire the global post may appear
    [double]$CooldownMinutes = 120.0,    # min gap between alerts
    [string]$LogPath = "$PSScriptRoot\..\logs\cluster-tour-watchdog.log",
    [string]$StateFile = "$PSScriptRoot\..\logs\cluster-tour-watchdog-state.json",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Invariant = [Globalization.CultureInfo]::InvariantCulture

# --- helpers ---

# Host stream, never the success stream: functions below log and then return a
# value, and a Write-Output line would be returned along with it.
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", $Invariant)
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry
    if ($DryRun) { return }
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
}

function Get-EnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    $line = Get-Content $Path -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", "").Trim().Trim('"').Trim("'") }
    return $null
}

function ConvertTo-UtcDateTime {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq "") { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    try {
        return [datetime]::Parse("$Value", $Invariant, [Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $null }
}

function Get-State {
    if (Test-Path $StateFile) {
        try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch { }
    }
    return @{ LastCheckedRunAt = $null; LastAlertAt = $null; OkCount = 0; MissingCount = 0; LastRun = $null }
}

function Set-State {
    param([hashtable]$State)
    if ($DryRun) { return }
    $State | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Send-Telegram {
    param([string]$Text)
    $token = Get-EnvValue $HostEnvFile "TELEGRAM_BOT_TOKEN"
    if (-not $token) { Write-Log "TELEGRAM_BOT_TOKEN missing from $HostEnvFile — cannot alert." "WARN"; return $false }
    try {
        $body = @{ chat_id = $ReviewChatId; text = $Text; disable_web_page_preview = $true } | ConvertTo-Json
        # PS 5.1 re-encodes a string body to ANSI (cp1252) on send, which breaks
        # any non-ASCII char ("Bad Request: strings must be encoded in UTF-8").
        # Send pre-encoded UTF-8 bytes instead.
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" `
            -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15
        return $true
    }
    catch {
        Write-Log "Telegram alert failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# One roosync_dashboard call over MCP HTTP: initialize, notifications/initialized
# (when the route hands out a session id — sparfenyuk does, TBXark does not),
# then tools/call. Routes are tried in order. Returns the response text, or
# $null when no route answered with a non-error result. Same transport as
# roo-extensions mcp-chain-watchdog.ps1 (Invoke-McpProbe / Publish-FleetNote).
function Invoke-RsmDashboard {
    param([hashtable]$Arguments)
    $bearer = Get-EnvValue $SecretsFile "MCP_AUTH_TOKEN"
    if (-not $bearer) { Write-Log "MCP_AUTH_TOKEN missing from $SecretsFile — no bus route." "WARN"; return $null }
    # Content-Type goes through -ContentType only: PS 5.1 can refuse it in -Headers too.
    $headers = @{
        'Authorization' = "Bearer $bearer"
        'Accept'        = 'application/json, text/event-stream'
    }
    $initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"hermes-cluster-tour-watchdog","version":"2.0"}}}'
    $callJson = @{
        jsonrpc = '2.0'; id = 2; method = 'tools/call'
        params  = @{ name = 'roosync_dashboard'; arguments = $Arguments }
    } | ConvertTo-Json -Depth 8 -Compress
    # Same PS 5.1 trap as Send-Telegram: a string body goes out as cp1252.
    $callBytes = [System.Text.Encoding]::UTF8.GetBytes($callJson)
    foreach ($url in $RsmUrls) {
        try {
            $init = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $initBody `
                -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $callHeaders = $headers
            $sid = $null
            foreach ($k in @($init.Headers.Keys)) { if ("$k" -ieq 'mcp-session-id') { $sid = $init.Headers[$k]; break } }
            if ($sid) {
                $callHeaders = @{} + $headers
                $callHeaders['mcp-session-id'] = "$sid"
                $null = Invoke-WebRequest -Uri $url -Method Post -Headers $callHeaders `
                    -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' `
                    -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
            }
            $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $callHeaders -Body $callBytes `
                -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec $BusTimeoutSec -ErrorAction Stop
            # Content can come back as bytes when the route answers in SSE.
            $content = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { "$($resp.Content)" }
            if ($resp.StatusCode -eq 200 -and $content -notmatch '"isError"\s*:\s*true') { return $content }
            Write-Log "bus route $url answered an error result" "WARN"
        } catch {
            Write-Log "bus route $url failed: $($_.Exception.Message)" "WARN"
        }
    }
    return $null
}

# Cluster-tour fire ANCHOR from jobs.json (host volume — works container-down).
# Anchor = last_dispatch.dispatched_at (START of the run), NOT last_run_at (END):
# ETAPE 3 executes during the run, so its [CLUSTER-HEALTH] append is always
# prior to last_run_at — a window anchored on the end time can structurally
# never contain the post it watches (roo-extensions #3743). Fallback to
# last_run_at for jobs.json entries predating the last_dispatch field.
function Get-ClusterTourFireAnchor {
    if (-not (Test-Path $JobsFile)) { Write-Log "jobs.json not found at $JobsFile" "WARN"; return $null }
    try {
        $data = Get-Content $JobsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($job in $data.jobs) {
            if ((-not $ClusterTourJobId -or "$($job.id)" -eq $ClusterTourJobId) -and $job.name -like "*cluster-tour*") {
                $anchor = $null
                if ($job.last_dispatch -and $job.last_dispatch.dispatched_at) {
                    $anchor = ConvertTo-UtcDateTime $job.last_dispatch.dispatched_at
                }
                if ($null -eq $anchor) { $anchor = ConvertTo-UtcDateTime $job.last_run_at }
                return $anchor
            }
        }
        Write-Log "cluster-tour job $ClusterTourJobId not found in jobs.json" "WARN"
        return $null
    } catch {
        Write-Log "jobs.json parse failed: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# Timestamp of the last message block whose TITLE is a tour post, read from
# global.md plus every archive written at or after $Since (an archive named
# global-<yyyy-MM-ddTHH-mm-ss>.md holds the blocks condensed away at that time).
# Blocks are formatted "### [<ts>] machine|workspace".
function Get-LastClusterHealthTimestamp {
    param([datetime]$Since)
    if (-not (Test-Path $GlobalDashFile)) { Write-Log "global.md not found at $GlobalDashFile" "WARN"; return $null }
    $files = @($GlobalDashFile)
    $archiveDir = Join-Path (Split-Path $GlobalDashFile -Parent) "archive"
    if (Test-Path $archiveDir) {
        foreach ($a in Get-ChildItem $archiveDir -Filter "global-*.md" -ErrorAction SilentlyContinue) {
            if ($a.Name -match '^global-(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})') {
                $archivedAt = ConvertTo-UtcDateTime "$($Matches[1])T$($Matches[2]):$($Matches[3]):$($Matches[4])Z"
                if ($null -ne $archivedAt -and $archivedAt -ge $Since) { $files += $a.FullName }
            }
        }
    }
    $lastTs = $null
    foreach ($f in $files) {
        try {
            $text = Get-Content $f -Raw -Encoding UTF8
            $pattern = '(?m)^### \[([0-9T:\-\.]+Z)\][^\r\n]*\r?\n([\s\S]*?)(?=^### \[|\z)'
            foreach ($m in [regex]::Matches($text, $pattern)) {
                $blockBody = $m.Groups[2].Value
                # Match the tour's section TITLE only, NOT a bare mention — the [WARN]
                # body itself says "no append [CLUSTER-HEALTH]" and would otherwise
                # self-validate as a posted tour. Three title formats exist:
                #   old  (<=T#71):  "## [CLUSTER-HEALTH] T#71 — 2026-09-01T12:20Z"
                #   new  (>=T#72):  "[CLUSTER-HEALTH] T#72 — Hermes (po-2026), 02/09 00:20Z"
                #   tags (>=T#112): "[CLUSTER-HEALTH][DONE] T#112 — Hermes po-2026 — 00:14Z"
                #                   (dashboard append renders the message tags inline)
                # Line-anchored + mandatory "T#<digits>" after the tag(s): the WARN
                # body only mentions [CLUSTER-HEALTH] mid-line, never as "T#N" at start.
                # "(?:\[[^\]]+\])*" tolerates any number of intercalated bracketed tags
                # (roo-extensions #3743: the strict "\s+T#N" successor matched nothing
                # since T#112, making last_health=never and every verdict MISSING).
                if ($blockBody -match "(?m)^#{0,2}\s*\[CLUSTER-HEALTH\](?:\[[^\]]+\])*\s+T#\d+") {
                    $t = ConvertTo-UtcDateTime $m.Groups[1].Value
                    if ($null -ne $t -and ($null -eq $lastTs -or $t -gt $lastTs)) { $lastTs = $t }
                }
            }
        } catch {
            Write-Log "dashboard parse failed ($f): $($_.Exception.Message)" "WARN"
        }
    }
    return $lastTs
}

function Get-WarnContent {
    param([string]$TourTs)
    return @(
        "## [WARN] cluster-tour ETAPE 3 non exécutée — tour $TourTs",
        "",
        "**Watchdog:** le fire ``hermes-cluster-tour`` ($TourTs UTC) a rapporté ``status=ok`` mais aucun append ``[CLUSTER-HEALTH]`` sur ce dashboard global dans les $PostMarginMinutes min suivantes (archives de condensation comprises). Cause possible : échec silencieux du write MCP (bus RooSync down, cf. incident 12→15/08 : instance RSM morte derrière sparfenyuk, handshake OK) OU prompt-skip (issue jsboige/hermes-agent #3). Croiser avec l'état du bus MCP (checks 6/8 de la routine opérateur). Vérification programmatique post-cron. Le tour n'est PAS re-firé (spec ai-01)."
    ) -join "`n"
}

# Post the [WARN] on global through the bus, so it lands in both halves of the
# v3 store and every dashboard reader of the cluster sees the hole where the
# tour post should have been. Idempotent per fire (messageId).
function Publish-GlobalWarn {
    param([datetime]$FireAnchor)
    $fireKey = $FireAnchor.ToString("yyyyMMddTHHmmssZ", $Invariant)
    $result = Invoke-RsmDashboard @{
        action    = 'append'
        type      = 'global'
        author    = @{ machineId = $SeatMachineId; workspace = $SeatWorkspace }
        tags      = @('WARN', 'cluster-tour-watchdog')
        messageId = "cluster-tour-watchdog-missing-$SeatMachineId-$fireKey"
        content   = Get-WarnContent $FireAnchor.ToString("o", $Invariant)
    }
    return ($null -ne $result -and $result -match 'success\\{0,2}"\s*:\s*true')
}

# --- main ---

$now = [datetime]::UtcNow
$state = Get-State
if ($DryRun) { Write-Log "DRY-RUN: no post, no alert, no state write, no log file." }

$fireAnchor = Get-ClusterTourFireAnchor
if ($null -eq $fireAnchor) {
    Write-Log "No cluster-tour fire anchor — cannot assert (source unavailable, not a MISSING)." "WARN"
    Set-State @{
        LastCheckedRunAt = $state.LastCheckedRunAt
        LastAlertAt      = $state.LastAlertAt
        OkCount          = $state.OkCount
        MissingCount     = $state.MissingCount
        LastRun          = $now.ToString("o", $Invariant)
    }
    exit 0
}

# -5 min grace below the anchor: with dispatched_at as anchor the tour post is by
# construction posterior to it; the grace only absorbs sync skew between the
# container write and the host-side read of the shared drive.
$lastHealth = Get-LastClusterHealthTimestamp -Since $fireAnchor.AddMinutes(-5)

# Only assert fires that are old enough for the post to have appeared AND that
# we have not already checked.
$prevChecked = ConvertTo-UtcDateTime $state.LastCheckedRunAt
$isNewFire    = $null -eq $prevChecked -or $fireAnchor -gt $prevChecked
$fireAgeMin   = ($now - $fireAnchor).TotalMinutes

$verdict = "SKIP"
$detail = ""
if ($isNewFire -and $fireAgeMin -ge $PostMarginMinutes) {
    $postOk = $null -ne $lastHealth -and $lastHealth -ge $fireAnchor.AddMinutes(-5)
    if ($postOk) {
        $verdict = "OK"
        $detail = "global [CLUSTER-HEALTH] @ $($lastHealth.ToString('o',$Invariant)) >= fire @ $($fireAnchor.ToString('o',$Invariant))"
    } else {
        $verdict = "MISSING"
        $lastHealthStr = if ($lastHealth) { $lastHealth.ToString("o", $Invariant) } else { "never" }
        $detail = "fire @ $($fireAnchor.ToString('o',$Invariant)) -> NO global [CLUSTER-HEALTH] (last seen $lastHealthStr)"
    }
} elseif ($isNewFire -and $fireAgeMin -lt $PostMarginMinutes) {
    $verdict = "PENDING"
    $detail = "fire @ $($fireAnchor.ToString('o',$Invariant)) still within ${PostMarginMinutes}min post window"
} else {
    $detail = "no new fire since last check ($prevChecked)"
}

# $lastHealth can legitimately be $null (no tour block in global.md yet, or the
# file was unreadable) — guard the interpolation, an unguarded .ToString() here
# crashed the script with exit 1 BEFORE any log line (2026-09-01T23:37Z incident)
# and under ErrorActionPreference=Stop wrote no verdict at every run (roo-extensions
# #3379). "never" = no tour block ever seen; "none" would be ambiguous vs unreadable.
$lastHealthStr = if ($null -ne $lastHealth) { $lastHealth.ToString('o', $Invariant) } else { "never" }
Write-Log "verdict=$verdict | $detail | fire_anchor=$($fireAnchor.ToString('o',$Invariant)) | last_health=$lastHealthStr | ok=$($state.OkCount) missing=$($state.MissingCount)"

$okCount    = $state.OkCount
$missingCount = $state.MissingCount
$newAlertAt = $state.LastAlertAt

if ($verdict -eq "OK") {
    $okCount = [int]$state.OkCount + 1
} elseif ($verdict -eq "MISSING") {
    $missingCount = [int]$state.MissingCount + 1

    $cooldownOk = $true
    $lastAlert = ConvertTo-UtcDateTime $state.LastAlertAt
    if ($lastAlert) {
        if ((($now - $lastAlert).TotalMinutes) -lt $CooldownMinutes) { $cooldownOk = $false }
    }
    $msg = "[CLUSTER-TOUR-WATCHDOG] MISSING — le fire cluster-tour @ $($fireAnchor.ToString('o',$Invariant)) n'a pas posté [CLUSTER-HEALTH] sur global. Verdict count: OK=$okCount MISSING=$missingCount. [WARN] posté sur global. Voir issue jsboige/hermes-agent #3."

    if ($DryRun) {
        Write-Log "DRY-RUN would post on global as $SeatMachineId|$SeatWorkspace :`n$(Get-WarnContent $fireAnchor.ToString('o', $Invariant))"
        Write-Log "DRY-RUN would send Telegram (cooldownOk=$cooldownOk): $msg"
    } else {
        $warnPosted = Publish-GlobalWarn $fireAnchor
        Write-Log "MISSING: [WARN] posted on global via the bus (posted=$warnPosted)." $(if ($warnPosted) { "INFO" } else { "ERROR" })
        if ($cooldownOk) {
            $sent = Send-Telegram $msg
            Write-Log "Telegram alert sent (sent=$sent)." $(if ($sent -eq $true) { "INFO" } else { "WARN" })
            # Only a delivered alert starts the cooldown: a failed send reached no one.
            if ($sent -eq $true) { $newAlertAt = $now.ToString("o", $Invariant) }
        } else {
            Write-Log "Alert suppressed (cooldown ${CooldownMinutes}min not elapsed)." "INFO"
        }
    }
}

if ($DryRun) {
    # Prove the write route without writing: one read-only call on the same path.
    $probe = Invoke-RsmDashboard @{ action = 'list' }
    $routeOk = $null -ne $probe -and $probe -match 'dashboards\\{0,2}"\s*:'
    Write-Log "DRY-RUN bus route probe (roosync_dashboard list): $(if ($routeOk) { 'OK' } else { 'FAILED' })" $(if ($routeOk) { "INFO" } else { "WARN" })
}

Set-State @{
    LastCheckedRunAt = if ($isNewFire) { $fireAnchor.ToString("o", $Invariant) } else { $state.LastCheckedRunAt }
    LastAlertAt      = $newAlertAt
    OkCount          = $okCount
    MissingCount     = $missingCount
    LastRun          = $now.ToString("o", $Invariant)
}
