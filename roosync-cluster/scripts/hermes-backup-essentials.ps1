# Hermes targeted GDrive backup — "ce qui compte", not the full volume.
# Mandate (user, 2026-10-23): everything that matters goes to GDrive; each
# workspace owns its recovery plan. Full-volume tars are explicitly rejected
# ("on n'a pas la place pour des backups aussi grossiers").
#
# Daily (default): memories/, SOUL.md, skills/, config.yaml, .env*, cron/jobs.json  (~3 MB)
# Weekly (-Weekly): + state.db gzipped (~226 MB) — conversation history, the
#                  exact loss that motivated the mandate.
# Secrets INCLUDED by explicit user decision (2026-10-23: "les configs, les
# memoires, les mdps, les dbs locales") — the destination folder lives on the
# shared RooSync Drive; move it off the shared root if that ever changes.
#
# Usage:  .\roosync-cluster\scripts\hermes-backup-essentials.ps1 [-Weekly]
# Rotation: essentials keep 14, state keep 4 (oldest deleted by name sort).

param([switch]$Weekly)

$ErrorActionPreference = "Stop"
$Volume = "$env:USERPROFILE\.hermes"
$Dest = "G:\Mon Drive\Synchronisation\RooSync\hermes-backups"
$Stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmm") + "Z"

if (-not (Test-Path "$Volume\state.db")) { Write-Error "No volume at $Volume"; exit 1 }

# --- destination readiness (boot race, measured 2026-10-30) ---
# The scheduled task runs with StartWhenAvailable: after a reboot it can fire
# within minutes, before Google Drive has mounted G:. Measured 12:02Z today:
# tar wrote a 0-byte archive and exited 1. Wait for the drive, bounded (2 min).
$DestReady = $false
for ($i = 1; $i -le 12; $i++) {
    if (Test-Path $Dest) { $DestReady = $true; break }
    if ($i -eq 1) { Write-Host "[WAIT] destination not reachable yet: $Dest" }
    Start-Sleep -Seconds 10
}
if (-not $DestReady) {
    if (-not (Test-Path "G:\")) { Write-Error "Drive G: not mounted after 2 min — destination unreachable"; exit 1 }
    New-Item -ItemType Directory -Force $Dest | Out-Null
}

# --- essentials (tar.exe ships with Windows 10+) ---
$Ess = Join-Path $Dest "hermes-essentials-$Stamp.tar.gz"
& tar.exe -czf $Ess -C $Volume memories SOUL.md skills config.yaml cron/jobs.json .env.secrets .env
# An exit code is not proof of product: check the archive itself (a 0-byte tar.gz
# can carry exit 1 — or worse, exit 0). Remove the empty artefact, then fail loudly.
$EssLen = if (Test-Path -LiteralPath $Ess) { (Get-Item -LiteralPath $Ess).Length } else { -1 }
if ($LASTEXITCODE -ne 0 -or $EssLen -le 0) {
    if ($EssLen -eq 0) { Remove-Item -LiteralPath $Ess -Force -ErrorAction SilentlyContinue }
    Write-Error "tar essentials failed (exit $LASTEXITCODE, product $EssLen B)"; exit 1
}
$EssHash = (Get-FileHash $Ess -Algorithm SHA256).Hash.Substring(0, 16)
Write-Host "[OK] essentials $Stamp -> $(Split-Path -Leaf $Ess) sha256[:16]=$EssHash"

# --- weekly: state.db ---
if ($Weekly) {
    $St = Join-Path $Dest "hermes-state-$Stamp.tar.gz"
    & tar.exe -czf $St -C $Volume state.db
    $StLen = if (Test-Path -LiteralPath $St) { (Get-Item -LiteralPath $St).Length } else { -1 }
    if ($LASTEXITCODE -ne 0 -or $StLen -le 0) {
        if ($StLen -eq 0) { Remove-Item -LiteralPath $St -Force -ErrorAction SilentlyContinue }
        Write-Error "tar state failed (exit $LASTEXITCODE, product $StLen B)"; exit 1
    }
    $StHash = (Get-FileHash $St -Algorithm SHA256).Hash.Substring(0, 16)
    Write-Host "[OK] state $Stamp -> $(Split-Path -Leaf $St) sha256[:16]=$StHash"
}

# --- rotation (delete oldest past keep-count; named files only, never the folder) ---
function Rotate([string]$Pattern, [int]$Keep) {
    $Files = Get-ChildItem -Path $Dest -Filter $Pattern -File | Sort-Object Name
    if ($Files.Count -gt $Keep) {
        $Files | Select-Object -First ($Files.Count - $Keep) | ForEach-Object {
            Write-Host "[ROT] removing $($_.Name)"
            Remove-Item $_.FullName -Confirm:$false
        }
    }
}
Rotate "hermes-essentials-*.tar.gz" 14
if ($Weekly) { Rotate "hermes-state-*.tar.gz" 4 }
Write-Host "Done. Dest=$Dest"
