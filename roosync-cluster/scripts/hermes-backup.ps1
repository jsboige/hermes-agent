# hermes-backup.ps1 — Manual pre-rebuild volume backup
# Usage: .\roosync-cluster\scripts\hermes-backup.ps1 [-Reason "description"] [-DryRun]
#
# Stops the container (SQLite consistency), tars the volume through a throwaway
# container, rotates to the last $MaxBackups archives, and ALWAYS restarts the
# container - including when a step after the stop throws.
param(
    [string]$Reason = "manual",
    # Show the plan (paths, image, rotation) and exit before stopping anything.
    [switch]$DryRun,
    # Must be present locally: a pull while the container is stopped is downtime.
    # alpine is what the restore procedure (CLAUDE.md) already uses.
    [string]$TarImage = "alpine:3.19"
)

$ErrorActionPreference = "Stop"
$ContainerName = "hermes"
# Paths follow the current user: a hardcoded profile breaks on every other seat.
$VolumePath = "$env:USERPROFILE\.hermes"
$BackupRoot = "$env:USERPROFILE\hermes-backups"
function ConvertTo-DockerPath { param([string]$Path) "/" + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/') }
$VolumePathUnix = ConvertTo-DockerPath $VolumePath
$BackupRootUnix = ConvertTo-DockerPath $BackupRoot
$MaxBackups = 5

if (-not (Test-Path $VolumePath)) { throw "Volume not found: $VolumePath" }

# 1. Plan
$Existing = @(Get-ChildItem "$BackupRoot\hermes-*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
$WouldRotate = @($Existing | Select-Object -Skip ($MaxBackups - 1))
docker image inspect $TarImage *> $null
$ImageLocal = $LASTEXITCODE -eq 0
$State = docker inspect --format '{{.State.Status}}' $ContainerName 2>$null
Write-Host "volume      : $VolumePath ($VolumePathUnix)"
Write-Host "backup root : $BackupRoot ($BackupRootUnix) - $($Existing.Count) existing"
Write-Host "tar image   : $TarImage ($(if ($ImageLocal) { 'local' } else { 'NOT local - pulled before the stop' }))"
Write-Host "container   : $ContainerName ($State)"
Write-Host "rotation    : $(if ($WouldRotate.Count) { ($WouldRotate | ForEach-Object Name) -join ', ' } else { 'none' })"
if ($DryRun) {
    Write-Host ""
    Write-Host "=== DRY RUN - container not stopped, nothing written ==="
    exit 0
}

# 2. Prepare everything that can fail BEFORE stopping the container
if (-not (Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    Write-Host "Created $BackupRoot"
}
if (-not $ImageLocal) {
    docker pull $TarImage
    if ($LASTEXITCODE -ne 0) { throw "Cannot pull $TarImage - container left running, no backup taken." }
}

$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "Z"
$BackupFile = Join-Path $BackupRoot "hermes-$Timestamp.tar.gz"

# 3. Stop, tar, restart (the restart runs whatever happens in between)
Write-Host "Stopping $ContainerName..."
docker stop $ContainerName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: Container stop failed or not running" -ForegroundColor Yellow
}
try {
    Write-Host "Creating backup: $BackupFile"
    # Build shell command as single line (backticks inside -c break with PS line continuation)
    $TarCmd = "tar -czf /backups/hermes-$Timestamp.tar.gz --exclude=.npm --exclude=logs --exclude=cache --exclude='*.pyc' --exclude=sandboxes --exclude=backups --exclude='./C:' -C '${VolumePathUnix}' ."
    docker run --rm -v "${VolumePathUnix}:${VolumePathUnix}" -v "${BackupRootUnix}:/backups" --entrypoint /bin/sh $TarImage -c $TarCmd
    if ($LASTEXITCODE -ne 0) { throw "Backup creation failed (tar exit $LASTEXITCODE)" }
}
finally {
    Write-Host "Restarting $ContainerName..."
    docker start $ContainerName 2>$null
}

# 4. Verify backup (gzip integrity, not just presence)
$BackupSize = (Get-Item $BackupFile).Length / 1MB
docker run --rm -v "${BackupRootUnix}:/backups" --entrypoint /bin/sh $TarImage -c "gzip -t /backups/hermes-$Timestamp.tar.gz"
if ($LASTEXITCODE -ne 0) { throw "Backup written but fails gzip -t: $BackupFile - rotation skipped" }
Write-Host "Backup created: $BackupFile ($([math]::Round($BackupSize, 1)) MB, gzip OK)"

# 5. Write metadata
$MetaFile = $BackupFile -replace '\.tar\.gz$', '.meta'
$Meta = "timestamp=$Timestamp`nreason=$Reason`nsize_mb=$([math]::Round($BackupSize, 1))`nhostname=$env:COMPUTERNAME`ncontainer=$ContainerName`n"
[System.IO.File]::WriteAllText($MetaFile, $Meta, [System.Text.UTF8Encoding]::new($false))

# 6. Rotation — keep last N backups (only after the new one verified)
$Backups = Get-ChildItem "$BackupRoot\hermes-*.tar.gz" | Sort-Object LastWriteTime -Descending
if ($Backups.Count -gt $MaxBackups) {
    $ToRemove = $Backups | Select-Object -Skip $MaxBackups
    foreach ($Old in $ToRemove) {
        $OldMeta = $Old.FullName -replace '\.tar\.gz$', '.meta'
        Remove-Item $Old.FullName -Force
        if (Test-Path $OldMeta) { Remove-Item $OldMeta -Force }
        Write-Host "Rotated: $($Old.Name)"
    }
}

# 7. Summary
Write-Host ""
Write-Host "=== BACKUP COMPLETE ===" -ForegroundColor Green
Write-Host "  File: $BackupFile"
Write-Host "  Size: $([math]::Round($BackupSize, 1)) MB"
Write-Host "  Reason: $Reason"
$Remaining = (Get-ChildItem "$BackupRoot\hermes-*.tar.gz").Count
Write-Host "  Backups retained: $Remaining / $MaxBackups"
