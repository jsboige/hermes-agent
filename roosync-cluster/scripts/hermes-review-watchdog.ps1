<#
.SYNOPSIS
    Hermes PR-review activity watchdog — detects SILENT review gaps.

.DESCRIPTION
    The pr-review cron (c8559be3577c, hourly at :23) can complete with status=ok
    yet post ZERO reviews. This silent failure happens when:
      - the model/provider breaks (e.g. the 2026-08-07 z.ai 429 storm + 964s
        timeouts that halted all reviews for hours before the claudish switch),
      - gh auth drifts, or the reviewable-PR heuristic skips everything.

    Cron status does NOT reflect actual review output, so this watchdog checks
    the BUSINESS signal directly: GitHub reviews posted by the bot across the
    target repos. If open PRs exist but no review has been posted within
    AlertThresholdHours, it alerts.

    Designed as an INDEPENDENT observer: it reads GH_TOKEN + TELEGRAM_BOT_TOKEN
    from the host volume and queries the GitHub REST API directly (Invoke-
    RestMethod), so it keeps alerting even when the Hermes container itself is
    down — which is exactly when the gap is most likely.

    Alert channel: Telegram message to the review chat (same channel pr-review
    delivers to). A cooldown (state file) prevents spam: one alert per
    CooldownHours. All runs log to review-watchdog.log.

    Date handling: Invoke-RestMethod auto-deserializes JSON dates to [datetime]
    under the current culture (fr-FR here), which breaks naive subtraction and
    string round-tripping. All timestamps are normalized to UTC [datetime] via
    ConvertTo-UtcDateTime and formatted with InvariantCulture to avoid comma
    decimals ("722,2h" bug).

.NOTES
    Deploy as a Windows Scheduled Task (every 30 min at :07/:37, hidden launcher):
    .\register-host-watchdog.ps1 -Watchdog review          # dry run
    .\register-host-watchdog.ps1 -Watchdog review -Apply

    Author: Hermes Agent workspace
#>

param(
    [string[]]$TargetRepos = @("jsboige/CoursIA", "jsboige/roo-extensions", "jsboige/jsboige-mcp-servers"),
    # Resolved from the token identity at run time when left empty. Do NOT hardcode:
    # the token identity has already drifted once. Reviews are currently posted as
    # `clusterManager-Myia` while this watchdog filtered on `jsboige` -> it could
    # never match a review, so it reported "has NEVER posted a review" every 30 min
    # while reviews were landing hourly. It was blind to exactly the silent gap it
    # exists to catch, and its ALERT text names a cause (pr-review failing) that the
    # data contradicted.
    [string]$BotLogin = "",
    # NanoClaw posts under the same login; only reviews whose body carries this
    # marker are Hermes's. Without it, NanoClaw's reviews would mask a Hermes outage.
    [string]$BodyMarker = "[Hermes",
    [double]$AlertThresholdHours = 4.0,
    [double]$CooldownHours = 4.0,
    # How many of the bot's latest reviews (all repos, newest first) are inspected.
    # NanoClaw shares the login; 100 (the GraphQL page maximum) spans well over the
    # alert threshold at both bots' combined review rate.
    [int]$MaxReviews = 100,
    # Host-side pr-review reports (same volume as $HostEnvFile). Used ONLY as a
    # REST cross-check before alerting: the bot's newest report names the PRs it
    # claims to have reviewed, and REST reads those PRs directly — immune to the
    # contributions-view lag (see the evaluate block).
    [string]$PrReviewReportsDir = "$env:USERPROFILE\.hermes\cron\output\hermes-pr-review-ai01",
    # Host volume (persists across container rebuilds) — read tokens here, NOT
    # from the container, so the watchdog works when the container is down.
    [string]$HostEnvFile = "$env:USERPROFILE\.hermes\.env",
    [string]$ReviewChatId = "-1003904676273",
    [string]$ContainerName = "hermes",
    [string]$LogPath = "$PSScriptRoot\..\logs\review-watchdog.log",
    [string]$StateFile = "$PSScriptRoot\..\logs\review-watchdog-state.json",
    # Evaluate and log the verdict, but send no alert and write no state.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Invariant = [Globalization.CultureInfo]::InvariantCulture

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

# Normalize a timestamp (Invoke-RestMethod gives [datetime] in current culture;
# strings come from elsewhere) to a UTC [datetime]. Avoids the op_Subtraction
# failure and comma-decimal display under fr-FR.
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
    return @{ LastAlert = $null; LastReviewSeen = $null; LastRun = $null }
}

function Set-State {
    param([hashtable]$State)
    $State | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Send-Telegram {
    param([string]$Text)
    $token = Get-EnvValue "TELEGRAM_BOT_TOKEN"
    # Write-Log emits on the success stream: inside this function it must go to the
    # host, or the caller receives @(logline, $false) - a truthy array - as "sent".
    if (-not $token) { Write-Log "TELEGRAM_BOT_TOKEN missing from $HostEnvFile — cannot alert." "WARN" | Out-Host; return $false }
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
        Write-Log "Telegram alert failed: $($_.Exception.Message)" "WARN" | Out-Host
        return $false
    }
}

function Invoke-Gh {
    param([string]$Path)
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $script:GhHeaders -TimeoutSec 20 -ErrorAction Stop
    }
    catch {
        # Surface GitHub's own explanation when there is one (rate limit / abuse
        # detection 403s carry a JSON message the bare exception hides).
        $detail = ""
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $detail = " | body: " + $sr.ReadToEnd()
            }
        } catch { }
        Write-Log "GitHub API call failed ($Path): $($_.Exception.Message)$detail" "WARN" | Out-Host
        return $null
    }
}

function Invoke-GhGraphQL {
    param([string]$Query)
    try {
        $body = [System.Text.Encoding]::UTF8.GetBytes((@{ query = $Query } | ConvertTo-Json -Compress))
        $r = Invoke-RestMethod -Uri "https://api.github.com/graphql" -Method Post -Headers $script:GhHeaders `
            -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 20 -ErrorAction Stop
        if ($r.errors) {
            Write-Log "GitHub GraphQL errors: $(($r.errors | ForEach-Object { $_.message }) -join '; ')" "WARN" | Out-Host
            return $null
        }
        return $r.data
    }
    catch {
        Write-Log "GitHub GraphQL call failed: $($_.Exception.Message)" "WARN" | Out-Host
        return $null
    }
}

# Third blindness, found 2026-10-24 19:37Z: the GraphQL contributions view ITSELF
# missed CoursIA reviews for ~5 h (last visible 14:35Z) while REST showed marked
# reviews at 17:33/17:50/19:01Z — the same CoursIA re-stamp waves that blinded the
# two PR samplings also lag this view, and CoursIA is where Hermes posts ~all its
# reviews. Before ALERTing, read the PRs the bot's newest report claims to have
# reviewed and ask REST directly. Only a report written in the last 3 h counts:
# a stale one says nothing about the current window and must not mask an outage.
function Get-RestMarkedReview {
    if (-not (Test-Path $PrReviewReportsDir)) { return $null }
    $report = Get-ChildItem $PrReviewReportsDir -Filter *.md -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $report) { return $null }
    if (($now - $report.LastWriteTimeUtc).TotalHours -gt 3) { return $null }
    $raw = Get-Content $report.FullName -Raw
    $idx = $raw.LastIndexOf('## Response')
    if ($idx -lt 0) { return $null }
    # "#22390 REQUEST_CHANGES (CoursIA, ..." — PR number, then a repo word nearby.
    # The report body embeds the job prompt (full of example PR numbers), so only
    # the section AFTER the last '## Response' heading is parsed.
    $candidates = @()
    foreach ($m in [regex]::Matches($raw.Substring($idx), '#(\d{4,6})([^\r\n]{0,60})')) {
        $pr = $m.Groups[1].Value
        $tail = $m.Groups[2].Value
        $repo = "jsboige/CoursIA"
        if ($tail -match 'Argumentum') { $repo = "jsboige/Argumentum" }
        elseif ($tail -match 'roo-extensions') { $repo = "jsboige/roo-extensions" }
        elseif ($tail -match 'mcp') { $repo = "jsboige/jsboige-mcp-servers" }
        $key = "$repo#$pr"
        if ($candidates -notcontains $key) { $candidates += $key }
    }
    $freshest = $null
    foreach ($c in ($candidates | Select-Object -First 2)) {
        $parts = $c -split '#'
        $reviews = Invoke-Gh "repos/$($parts[0])/pulls/$($parts[1])/reviews?per_page=30"
        if ($null -eq $reviews) { continue }
        foreach ($rv in @($reviews)) {
            if ($rv.user.login -ne $BotLogin) { continue }
            if (-not ([string]$rv.body).Contains($BodyMarker)) { continue }
            $t = ConvertTo-UtcDateTime $rv.submitted_at
            if ($null -eq $t) { continue }
            if ($null -eq $freshest -or $t -gt $freshest) { $freshest = $t }
        }
    }
    return $freshest
}

# --- setup ---

$ghToken = Get-EnvValue "GH_TOKEN"
if (-not $ghToken) {
    Write-Log "GH_TOKEN missing from $HostEnvFile — cannot check review activity. Aborting." "ERROR"
    exit 1
}
$script:GhHeaders = @{
    Authorization          = "Bearer $ghToken"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "hermes-review-watchdog"
}

# Resolve the review bot's login from the token itself (see the $BotLogin note above).
# Abort rather than continue with an empty login: an empty login matches no review,
# which is indistinguishable from "the bot never reviews" and is the exact failure
# this organ was blind to. Failing loudly is the only honest option here.
if (-not $BotLogin) {
    # 2026-10-19: every :37 tick failed with a transient 403 on /user while every
    # :07 tick of the same script/token succeeded (5 in a row) - a single-shot
    # probe here was losing half the ticks. Retry with backoff before aborting.
    $me = $null
    foreach ($attempt in 1..3) {
        $me = Invoke-Gh "user"
        if ($me -and $me.login) { break }
        if ($attempt -lt 3) {
            Write-Log "Login resolution attempt $attempt/3 failed - retrying in 20s." "WARN" | Out-Host
            Start-Sleep -Seconds 20
        }
    }
    if ($me -and $me.login) {
        $BotLogin = $me.login
        Write-Log "Bot login resolved from the token: $BotLogin" "INFO"
    }
    else {
        Write-Log "Could not resolve the bot login from GH_TOKEN (3 attempts) — review detection would match nothing and cry wolf. Aborting." "ERROR"
        exit 1
    }
}

# --- collect review activity across target repos ---

$now = [datetime]::UtcNow
$totalOpenPrs = 0
$latestReview = $null   # UTC [datetime] of the most recent marked bot review
$repoLatest = @{}
$repoSummary = @()

# The bot's own reviews, newest first, across all repos, in ONE call. Any sampling by
# PR went blind: first the newest OPEN PRs (14/10 22:32Z, "never" for CoursIA 12 min
# after a Hermes review there), then the PRs the bot reviewed sorted by `updated` -
# 5788 of them on CoursIA, and one bulk-update wave (15/10 01:53Z, dozens of PRs in
# seconds) pushed every fresh review out of the window: it read 2.8h while Hermes
# had reviewed 14 min earlier.
$data = Invoke-GhGraphQL "query { user(login: `"$BotLogin`") { contributionsCollection { pullRequestReviewContributions(first: $MaxReviews, orderBy: {direction: DESC}) { nodes { pullRequestReview { submittedAt body } pullRequest { repository { nameWithOwner } } } } } } }"
if ($null -eq $data -or $null -eq $data.user) {
    # Without the reviews there is no verdict: "no review found" would cry wolf.
    Write-Log "Could not read the reviews of $BotLogin — no verdict this tick." "ERROR"
    exit 1
}
foreach ($n in $data.user.contributionsCollection.pullRequestReviewContributions.nodes) {
    $repo = $n.pullRequest.repository.nameWithOwner
    if ($TargetRepos -notcontains $repo) { continue }
    if (-not ([string]$n.pullRequestReview.body).Contains($BodyMarker)) { continue }
    $t = ConvertTo-UtcDateTime $n.pullRequestReview.submittedAt
    if ($null -eq $t) { continue }
    if (-not $repoLatest.ContainsKey($repo) -or $t -gt $repoLatest[$repo]) { $repoLatest[$repo] = $t }
    if ($null -eq $latestReview -or $t -gt $latestReview) { $latestReview = $t }
}

foreach ($repo in $TargetRepos) {
    # Open-PR count only: is there anything to review at all? One page, so 100 means 100+.
    $pulls = Invoke-Gh "repos/$repo/pulls?state=open&per_page=100"
    if ($null -eq $pulls) { $repoSummary += "$repo=(query-failed)"; continue }
    $openCount = @($pulls).Count
    $totalOpenPrs += $openCount
    # "none" means none among the bot's $MaxReviews latest reviews, not "never".
    $age = if ($repoLatest.ContainsKey($repo)) { (($now - $repoLatest[$repo]).TotalHours).ToString("F1", $Invariant) + "h" } else { "none" }
    $repoSummary += "$repo(open=$(if ($openCount -ge 100) { '100+' } else { $openCount }),lastMarkedReview=$age)"
}

# --- evaluate ---

$hoursSince = $null
if ($latestReview) { $hoursSince = ($now - $latestReview).TotalHours }

$containerUp = $false
try {
    $st = docker inspect --format='{{.State.Status}}' $ContainerName 2>$null
    if ($LASTEXITCODE -eq 0 -and $st -eq "running") { $containerUp = $true }
} catch { }

$wouldAlert = ($totalOpenPrs -gt 0) -and (($null -eq $hoursSince) -or ($hoursSince -ge $AlertThresholdHours))
if ($wouldAlert) {
    # The GraphQL view may be wave-blind (see Get-RestMarkedReview): verify against
    # REST before crying wolf. A fresher REST finding replaces $latestReview so the
    # summary and the LastReviewSeen state stay truthful.
    $restLatest = Get-RestMarkedReview
    if ($restLatest -and (($null -eq $latestReview) -or ($restLatest -gt $latestReview))) {
        $latestReview = $restLatest
        $hoursSince = ($now - $latestReview).TotalHours
        if ($hoursSince -lt $AlertThresholdHours) {
            Write-Log "GraphQL contributions view STALE — REST cross-check found a marked review at $($latestReview.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)); would-be ALERT downgraded to OK (CoursIA wave blindness)." "WARN"
            $wouldAlert = $false
        }
    }
}

$status = "OK"
if ($totalOpenPrs -eq 0) {
    $detail = "no open PRs to review across $($TargetRepos -join ', ')"
}
elseif ($wouldAlert -and $null -eq $hoursSince) {
    $status = "ALERT"
    $detail = "$totalOpenPrs open PR(s) but no review marked '$BodyMarker' among the $MaxReviews latest reviews of $BotLogin (REST cross-check concurs)"
}
elseif ($wouldAlert) {
    $status = "ALERT"
    $detail = "no review in $([Math]::Round($hoursSince,1).ToString($Invariant))h (threshold ${AlertThresholdHours}h) despite $totalOpenPrs open PR(s) (REST cross-check concurs)"
}
else {
    $detail = "last review $([Math]::Round($hoursSince,1).ToString($Invariant))h ago, $totalOpenPrs open PR(s)"
}

$summary = "$status - $detail. Repos: $($repoSummary -join '; '). Container: $(if($containerUp){'up'}else{'DOWN'})."
Write-Log $summary $(if ($status -eq "ALERT") { "ERROR" } else { "INFO" })

if ($DryRun) {
    Write-Log "DRY RUN - no alert sent, state not written$(if ($status -eq 'ALERT') { ' (a real run would have alerted, cooldown permitting)' })." "INFO"
    exit 0
}

# --- alert (with cooldown) ---

$state = Get-State
$shouldAlert = $false
if ($status -eq "ALERT") {
    $cooldownOk = $true
    $lastAlert = ConvertTo-UtcDateTime $state.LastAlert
    if ($lastAlert) {
        if ((($now - $lastAlert).TotalHours) -lt $CooldownHours) { $cooldownOk = $false }
    }
    if ($cooldownOk) {
        $msg = "[REVIEW-WATCHDOG] $summary`n`nThe pr-review cron may be failing silently (status=ok, zero output). Check: gateway logs for 429/timeout/auth errors, gh auth in container, provider health."
        $sent = Send-Telegram $msg
        # Only a DELIVERED alert starts the cooldown. Setting $shouldAlert before the
        # send meant a failed delivery (measured 2026-10-09 08:07Z, request timeout)
        # still stamped LastAlert and suppressed the next 4h — the alert was silently
        # lost. A failed send costs nothing to retry: nothing reaches Telegram.
        $shouldAlert = $sent -eq $true
        Write-Log "Alert to Telegram chat $ReviewChatId (sent=$sent)." $(if ($sent) { "INFO" } else { "WARN" })
    }
    else {
        Write-Log "Alert suppressed (cooldown ${CooldownHours}h not elapsed since last alert)." "INFO"
    }
}

Set-State @{
    LastRun        = $now.ToString("o", $Invariant)
    LastAlert      = if ($shouldAlert) { $now.ToString("o", $Invariant) } else { $state.LastAlert }
    LastReviewSeen = if ($latestReview) { $latestReview.ToString("o", $Invariant) } else { $null }
}
