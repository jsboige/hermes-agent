<#
.SYNOPSIS
    Hermes cron-output watchdog — detects cron runs that FAIL SILENTLY.

.DESCRIPTION
    A cron run can die mid-flight and still be recorded as `status=ok`. Measured
    2026-10-08/09: 11 runs across 4 of the 5 Hermes lanes ended on a malformed
    tool call emitted by the hub-served model —

        Tool call "tool_call" failed: missing required parameters: calls.

    — which the framework turns into the run's FINAL RESPONSE (181 chars),
    delivers to Telegram, and records as `ok`. Nothing in jobs.json shows it.
    Consequence: a `[CLUSTER-HEALTH]` tour was silently skipped on 2026-10-08
    12:13Z, and 9 further failures left no trace at all.

    Only `hermes-cluster-tour` has a watchdog. This one covers ALL lanes by
    reading the per-run reports the cron scheduler writes to
    `<hermes home>/cron/output/<job-id>/<timestamp>.md`, which carry both the
    run's `Response Characters` count and its full response body.

    Two signals (precision + recall):
      THREAD-FAIL  — the body contains the malformed-tool-call marker string.
      SHORT-OUTPUT — `Response Characters` below MinChars. A real report is
                     ~400-2000 chars; a run that produced nothing meaningful is
                     a few dozen. This is the cheapest instrument that would
                     have caught all 11.

    IMPORTANT — THREAD-FAIL does NOT mean the run's work was lost. The abort can
    land anywhere in the run, and the two measured cases differ:
      - 2026-10-08 12:13Z cluster-tour died BEFORE posting -> [CLUSTER-HEALTH]
        T#161 was never written (the tour watchdog alerted for it at 12:37Z).
      - 2026-10-09 00:13Z cluster-tour posted T#162 at 00:21:46Z and then died
        at 00:22:12Z -> the abort cost nothing but the run's own summary.
    So this organ reports the ABORT and stops there. Whether work was lost is
    per-run and has to be read from the report body; only lane-specific
    watchdogs (e.g. hermes-cluster-tour-watchdog.ps1) can judge that.

    INDEPENDENT observer: reads everything from the host volume, so it keeps
    alerting while the container is down — exactly when a silent failure is
    most likely to go unnoticed.

    Alert behaviour: EVERY failure is written to the log (full instrumentation,
    the rate is the data); Telegram alerts are aggregated per run and rate-
    limited by a state-file cooldown so a burst does not become spam.

    File tracking: already-reported files are remembered in the state file, so
    a failure alerts once, not once per tick. Only files modified within
    LookbackHours are scanned.

.NOTES
    Deploy as a Windows Scheduled Task on po-2026 (same pattern as
    hermes-review-watchdog.ps1):
    - Trigger: every 30 minutes (off-minute, e.g. :11/:41 — deliberately
      distinct from the review/MCP watchdogs' :07/:37)
    - Action: powershell -NoProfile -File "...\hermes-cron-output-watchdog.ps1"
    - Run whether user is logged on or not

    Author: Hermes Agent workspace
#>

param(
    # Hermes home on the host volume (persists across rebuilds).
    [string]$HermesHome = "C:\Users\jsboi\.hermes",
    # A run whose response is shorter than this produced nothing meaningful.
    [int]$MinChars = 300,
    # Only inspect reports modified this recently.
    [double]$LookbackHours = 26.0,
    # At most one aggregated Telegram alert per cooldown window.
    [double]$CooldownHours = 3.0,
    # Cap on remembered filenames (keeps the state file small).
    [int]$MaxSeen = 400,
    [string]$HostEnvFile = "C:\Users\jsboi\.hermes\.env",
    [string]$ReviewChatId = "-1003904676273",
    # Validate detection and logging without sending any Telegram alert, and
    # without touching the state file. Use this to prove the organ works before
    # arming it.
    [switch]$DryRun,
    # One-time: adopt every failure currently in the window as already-known and
    # alert nothing. Used when arming the organ on an existing backlog, so the
    # first production tick reports 0 new instead of dumping the whole history.
    [switch]$Seed,
    [string]$LogPath = "$PSScriptRoot\..\logs\cron-output-watchdog.log",
    [string]$StateFile = "$PSScriptRoot\..\logs\cron-output-watchdog-state.json"
)

$ErrorActionPreference = "Stop"
$Invariant = [Globalization.CultureInfo]::InvariantCulture

# Exact marker the framework prints when the model emits an unusable tool call.
$ThreadFailMarker = 'missing required parameters: calls'

# --- helpers ---

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", $Invariant)
    $entry = "[$timestamp] [$Level] $Message"
    Write-Output $entry
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
}

function Get-EnvValue {
    param([string]$Key)
    if (-not (Test-Path $HostEnvFile)) { return $null }
    $line = Get-Content $HostEnvFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", "") }
    return $null
}

function Get-State {
    if (Test-Path $StateFile) {
        try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ LastAlert = $null; LastRun = $null; SeenFiles = @(); FailureCount = 0 }
}

function Set-State {
    param($State)
    $State | ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding UTF8
}

function Send-Telegram {
    param([string]$Text)
    $token = Get-EnvValue "TELEGRAM_BOT_TOKEN"
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

# job-id -> human name, from the live jobs.json (never hardcoded, so a renamed
# or added lane is labelled correctly without touching this script).
function Get-JobNameMap {
    $map = @{}
    $jobsFile = Join-Path $HermesHome "cron\jobs.json"
    if (-not (Test-Path $jobsFile)) { return $map }
    try {
        $raw = Get-Content $jobsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $jobs = if ($raw -is [array]) { $raw } elseif ($raw.jobs) { $raw.jobs } else { @() }
        foreach ($j in $jobs) {
            $id = "$($j.id)"
            if ($id) { $map[$id] = "$($j.name)" }
        }
    } catch {
        Write-Log "Could not parse jobs.json for lane names: $($_.Exception.Message)" "WARN"
    }
    return $map
}

# --- setup ---

$now = [datetime]::UtcNow
$outputRoot = Join-Path $HermesHome "cron\output"
if (-not (Test-Path $outputRoot)) {
    Write-Log "cron output root not found at $outputRoot — nothing to inspect." "WARN"
    exit 0
}

$state = Get-State
$seen = @()
if ($state.SeenFiles) { $seen = @($state.SeenFiles) }
$jobNames = Get-JobNameMap

# --- scan reports ---

$cutoff = $now.AddHours(-$LookbackHours)
$failures = @()

foreach ($dir in (Get-ChildItem -Path $outputRoot -Directory -ErrorAction SilentlyContinue)) {
    $jobId = $dir.Name
    $label = if ($jobNames.ContainsKey($jobId)) { $jobNames[$jobId] } else { $jobId }

    $reports = Get-ChildItem -Path $dir.FullName -Filter "*.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoff }

    foreach ($r in $reports) {
        $key = "$jobId/$($r.Name)"
        if ($seen -contains $key) { continue }
        # The report is written when the run ENDS, so a file touched in the last
        # two minutes may still be flushing — evaluating it mid-write would read
        # a truncated body and raise a false SHORT-OUTPUT.
        if (($now - $r.LastWriteTimeUtc).TotalMinutes -lt 2) { continue }

        $body = Get-Content $r.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $body) { continue }

        $reason = $null
        if ($body -match [regex]::Escape($ThreadFailMarker)) {
            $reason = "THREAD-FAIL"
        }
        else {
            # "**Response Characters:** 181"
            $m = [regex]::Match($body, 'Response Characters:\*{0,2}\s*(\d+)')
            if ($m.Success) {
                $chars = [int]$m.Groups[1].Value
                if ($chars -lt $MinChars) { $reason = "SHORT-OUTPUT" }
            }
        }

        if ($reason) {
            $failures += [pscustomobject]@{
                Job    = $label
                JobId  = $jobId
                File   = $r.Name
                When   = $r.LastWriteTimeUtc
                Reason = $reason
            }
            Write-Log "FAILURE $reason — $label ($($r.Name), $($r.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)))" "ERROR"
        }
    }
}

# --- evaluate ---

$totalFailures = [int]$state.FailureCount + $failures.Count
$cooldownOk = $false

if ($failures.Count -eq 0) {
    Write-Log "OK - no new cron output failure in the last ${LookbackHours}h (cumulative seen: $totalFailures)." "INFO"
}
else {
    $byLane = ($failures | Group-Object Job | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ", "
    Write-Log "DETECTED $($failures.Count) new silent failure(s): $byLane (cumulative: $totalFailures)." "ERROR"

    # Built unconditionally: the dry run must be able to show exactly what
    # would have been sent.
    $lines = $failures | Sort-Object When | ForEach-Object {
        "  - $($_.Job) @ $($_.When.ToString('MM-dd HH:mm', $Invariant))Z [$($_.Reason)]"
    }
    $msg = @(
        "[CRON-OUTPUT-WATCHDOG] $($failures.Count) cron run(s) FAILED SILENTLY",
        "",
        ($lines -join "`n"),
        "",
        "$totalFailures cumulative. These runs are recorded status=ok: each aborted on a malformed tool call from the hub-served model (192.168.0.50:3000) and that error text became the run's final response. An abort does NOT always mean lost work - a run that posted before aborting cost nothing. Read <hermes home>/cron/output/<job-id>/ to tell which case it was."
    ) -join "`n"

    $cooldownOk = $true
    if ($state.LastAlert) {
        try {
            $last = [datetime]::Parse("$($state.LastAlert)", $Invariant, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if ((($now - $last).TotalHours) -lt $CooldownHours) { $cooldownOk = $false }
        } catch { }
    }

    if ($DryRun) {
        Write-Log "DRY RUN - alert suppressed, state not written. Would have sent:`n$msg" "INFO"
        exit 0
    }

    if ($Seed) {
        Write-Log "SEED - adopting $($failures.Count) existing failure(s) as already-known; no alert sent and no cooldown started." "INFO"
    }
    elseif ($cooldownOk) {
        $sent = Send-Telegram $msg
        Write-Log "Alert sent to Telegram chat $ReviewChatId (sent=$sent)." $(if ($sent) { "INFO" } else { "WARN" })
    }
    else {
        Write-Log "Alert suppressed (cooldown ${CooldownHours}h not elapsed since last alert)." "INFO"
    }
}

# --- persist state ---

# Remember every failure reported so a later tick never double-counts it.
# Successful reports are deliberately NOT remembered: they can never turn into
# a failure afterwards, so re-reading them is harmless and keeps the state small.
$newSeen = @($seen)
foreach ($f in $failures) {
    $k = "$($f.JobId)/$($f.File)"
    if ($newSeen -notcontains $k) { $newSeen += $k }
}
if ($newSeen.Count -gt $MaxSeen) { $newSeen = $newSeen[($newSeen.Count - $MaxSeen)..($newSeen.Count - 1)] }

Set-State ([pscustomobject]@{
    LastRun       = $now.ToString("o", $Invariant)
    LastAlert     = if ($failures.Count -gt 0 -and $cooldownOk -and -not $Seed) { $now.ToString("o", $Invariant) } else { $state.LastAlert }
    SeenFiles     = $newSeen
    FailureCount  = $totalFailures
})
