# hermes-backup.ps1 — Manual pre-rebuild volume backup
# Usage: .\roosync-cluster\scripts\hermes-backup.ps1 [-Reason "description"]
param(
    [string]$Reason = "manual"
)

$ErrorActionPreference = "Stop"
$ContainerName = "hermes"
$VolumePath = "C:\Users\jsboi\.hermes"
$VolumePathUnix = "/c/Users/jsboi/.hermes"
$BackupRoot = "C:\Users\jsboi\hermes-backups"
$BackupRootUnix = "/c/Users/jsboi/hermes-backups"
$MaxBackups = 5

# 1. Ensure backup directory
if (-not (Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    Write-Host "Created $BackupRoot"
}

# 2. Stop container for SQLite consistency
Write-Host "Stopping $ContainerName..."
docker stop $ContainerName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: Container stop failed or not running" -ForegroundColor Yellow
}

# 3. Create backup
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupFile = Join-Path $BackupRoot "hermes-$Timestamp.tar.gz"

Write-Host "Creating backup: $BackupFile"

# Use docker run with the same volume to tar (avoids host tar path issues on Windows)
# Build shell command as single line (backticks inside -c break with PS line continuation)
$TarCmd = "tar -czf /backups/hermes-$Timestamp.tar.gz --exclude=.npm --exclude=logs --exclude=cache --exclude='*.pyc' --exclude=sandboxes --exclude=backups --exclude='./C:' -C '${VolumePathUnix}' ."
docker run --rm -v "${VolumePathUnix}:${VolumePathUnix}" -v "${BackupRootUnix}:/backups" --entrypoint /bin/sh debian:13 -c $TarCmd

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Backup creation failed" -ForegroundColor Red
    Write-Host "Restarting container..."
    docker start $ContainerName 2>$null
    exit 1
}

# 4. Verify backup
$BackupSize = (Get-Item $BackupFile).Length / 1MB
Write-Host "Backup created: $BackupFile ($([math]::Round($BackupSize, 1)) MB)"

# 5. Write metadata
$MetaFile = $BackupFile -replace '\.tar\.gz$', '.meta'
@"
timestamp=$Timestamp
reason=$Reason
size_mb=$([math]::Round($BackupSize, 1))
hostname=$env:COMPUTERNAME
container=$ContainerName
"@ | Set-Content -Path $MetaFile -Encoding UTF8NoBOM

# 6. Rotation — keep last N backups
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

# 7. Restart container
Write-Host "Restarting $ContainerName..."
docker start $ContainerName 2>$null

# 8. Summary
Write-Host ""
Write-Host "=== BACKUP COMPLETE ===" -ForegroundColor Green
Write-Host "  File: $BackupFile"
Write-Host "  Size: $([math]::Round($BackupSize, 1)) MB"
Write-Host "  Reason: $Reason"
$Remaining = (Get-ChildItem "$BackupRoot\hermes-*.tar.gz").Count
Write-Host "  Backups retained: $Remaining / $MaxBackups"
