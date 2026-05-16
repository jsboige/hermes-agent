# Hermes one-shot post-rebuild restore
# Usage: .\roosync-cluster\scripts\hermes-restore.ps1
#
# Does everything: copies secrets + restore script into container, executes, restarts.
# Requires: Docker running, hermes container exists, .env.secrets present.

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot ".." "..")
$SecretsFile = Join-Path $RepoRoot "roosync-cluster\config\.env.secrets"
$RestoreScript = Join-Path $RepoRoot "roosync-cluster\scripts\hermes-restore-config.sh"
$Container = "hermes"

# Check prerequisites
if (-not (docker ps --filter "name=$Container" --format "{{.Names}}" 2>$null)) {
    # Try stopped container
    if (-not (docker ps -a --filter "name=$Container" --format "{{.Names}}" 2>$null)) {
        Write-Error "Container '$Container' not found. Deploy first."
        exit 1
    }
    Write-Host "Container '$Container' is stopped. Starting it..."
    docker start $Container
    if (-not $?) { Write-Error "Failed to start container."; exit 1 }
    Start-Sleep -Seconds 3
}

if (-not (Test-Path $SecretsFile)) {
    Write-Error "Missing $SecretsFile — create it with all tokens (GLM_API_KEY, TELEGRAM_BOT_TOKEN, etc.)"
    exit 1
}

if (-not (Test-Path $RestoreScript)) {
    Write-Error "Missing $RestoreScript"
    exit 1
}

Write-Host "[1/4] Copying .env.secrets into container..."
docker cp $SecretsFile "${Container}:/opt/data/.env.secrets"

Write-Host "[2/4] Copying restore script into container..."
docker cp $RestoreScript "${Container}:/opt/data/restore-config.sh"

Write-Host "[3/4] Running restore script..."
docker exec $Container bash /opt/data/restore-config.sh

Write-Host "[4/4] Restarting container..."
docker restart $Container

Write-Host ""
Write-Host "Done. Hermes restored and restarted." -ForegroundColor Green
