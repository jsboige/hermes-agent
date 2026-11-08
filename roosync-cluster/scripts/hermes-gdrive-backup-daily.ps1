# Daily driver for the targeted GDrive backup (user mandate 2026-10-23:
# "Absolument tout doit être backupé sur GDrive", essentials daily + state weekly).
#
# Why a wrapper: hermes-backup-essentials.ps1 only rotates the state archives
# when -Weekly is passed, and only the caller knows it is Sunday. Before this
# task existed the daily pass was triggered by the 3h surveillance cron "at the
# 01:53Z fire" — but that cron's minute offset is re-derived at every re-arm
# (measured drift :53 -> :33 -> :24 on 25/10), so the pass silently stopped
# happening. A backup must not depend on which minute a cron lands on.
#
# Sunday (UTC) adds -Weekly: state.db (the conversation history whose loss
# motivated the mandate). Log: roosync-cluster/logs/gdrive-backup.log.
# Read the LOG, not only LastTaskResult: an exit code can be red while the work
# succeeded (measured on the NanoClaw backup, 24/10), and green proves nothing
# about what was produced. Verify: newest hermes-essentials-*.tar.gz < 26h old.

param([switch]$Weekly)

$ErrorActionPreference = "Stop"
$LogDir = Join-Path $PSScriptRoot "..\logs"
$LogFile = Join-Path $LogDir "gdrive-backup.log"

function Write-Log {
    param([string]$Text, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"), $Level, $Text
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    Write-Host $line
}

try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
    $isSunday = ([DateTimeOffset]::UtcNow.DayOfWeek -eq [DayOfWeek]::Sunday)
    $doWeekly = $Weekly -or $isSunday
    Write-Log ("start essentials" + $(if ($doWeekly) { " + weekly state.db (Sunday or -Weekly)" } else { "" }))
    $script = Join-Path $PSScriptRoot "hermes-backup-essentials.ps1"
    if ($doWeekly) { & $script -Weekly } else { & $script }
    if ($LASTEXITCODE -ne 0) { throw "essentials exited $LASTEXITCODE" }
    # Proof of product, not just of exit code: an archive younger than this run.
    $dest = "G:\Mon Drive\Synchronisation\RooSync\hermes-backups"
    $newest = Get-ChildItem $dest -Filter "hermes-essentials-*.tar.gz" -File |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $newest -or $newest.Length -lt 1000) { throw "no usable essentials archive produced" }
    Write-Log ("OK produced {0} ({1:N0} bytes, {2})" -f $newest.Name, $newest.Length, $newest.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
    exit 0
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "ERROR"
    exit 1
}
