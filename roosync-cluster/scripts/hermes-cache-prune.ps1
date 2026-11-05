<#
.SYNOPSIS
  Élagage périodique par AGE du scratch du bot Hermes (conteneur `hermes`).

.DESCRIPTION
  Le 05/11/2026, le volume `C:\Users\MYIA\.hermes` a été trouvé à ~90 Go dont
  `cache/scratch` = 73 Go, soit x3,5 en deux jours. La cause est structurelle :
  chaque run pr-review/audit laisse ses artefacts (`pr<N>/`, `review_*.txt`,
  `payload_*.json`, notebooks de rejeu) et rien ne les retire jamais. Un élagage
  manuel a rendu ~73 Go ; sans garde, le volume reprend la même pente.

  Cette garde applique la MÊME règle que l'élagage manuel validé par l'utilisateur
  (GO verbatim 05/11 : « Ok pour un élagage ciblé de toute ce qui est regénérable ») :
    - `cache/scratch/*` non-`hermes_*`  plus vieux que -MainHours  (48 h par défaut)
    - `cache/scratch/hermes_*`          plus vieux que -KernelHours (72 h par défaut)
      (entités du gateway : kernels jupyter + sockets RPC ; une entrée vivante est
       récente, une entrée de 72 h est un kernel mort)
    - `audit-17073/*`                   plus vieux que -AuditHours  (72 h par défaut)
  Aucune donnée du bot n'est visée : `state.db`, `skills`, `logs`, `memories`,
  `sessions`, `config.yaml`, `.env*` et les toolchains (`home/.elan`, `home/.local`,
  `.local`, `.solcx`, `.pytensor`) ne sont JAMAIS touchés.

  Le critère est l'AGE, pas le nom : un run en vol écrit dans des entrées fraîches,
  donc elles sont hors d'atteinte par construction.

  Par défaut le script est en DRY-RUN (compte et mesure, ne supprime rien).
  `-Apply` exécute. `-MaxDeleteGB` borne la quantité supprimée par passage.

.PARAMETER Apply
  Exécute réellement la suppression. Sans ce commutateur : dry-run.

.PARAMETER MainHours
  Âge minimal (heures) du scratch de travail. Défaut 48.

.PARAMETER KernelHours
  Âge minimal (heures) des entités `hermes_*` (kernels/sockets). Défaut 72.

.PARAMETER AuditHours
  Âge minimal (heures) des artefacts d'audit. Défaut 72.

.PARAMETER MaxDeleteGB
  Plafond de sécurité en Go par passage. Défaut 40.

.EXAMPLE
  .\hermes-cache-prune.ps1                 # dry-run : montre ce qui partirait
  .\hermes-cache-prune.ps1 -Apply          # supprime
  .\hermes-cache-prune.ps1 -Apply -MainHours 24 -AuditHours 48

.NOTES
  Tâche hôte attendue : `Hermes-Cache-Pruner`, quotidienne, non élevée.
  Journal : roosync-cluster/logs/cache-prune.log
  Postconditions : ne supprime qu'en dehors des fenêtres fraîches ; jamais de rm
  récursif sur un chemin non nommé ; manifeste horodaté écrit avant suppression.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [int]$MainHours = 48,
    [int]$KernelHours = 72,
    [int]$AuditHours = 72,
    [int]$MaxDeleteGB = 40
)

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'cache-prune.log'

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f ([DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $Message
    $line | Add-Content -Path $LogFile -Encoding utf8
    Write-Output $line
}

# --- 1. Conteneur présent ? (lecture seule) ---------------------------------
$running = & docker ps --filter 'name=hermes' --format '{{.Names}}'
if (-not ($running -match 'hermes')) {
    Write-Log 'SKIP - conteneur hermes absent (rien à élaguer)'
    exit 0
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Log ("START {0} main>{1}h kernel>{2}h audit>{3}h cap={4}GB" -f $mode, $MainHours, $KernelHours, $AuditHours, $MaxDeleteGB)

# --- 2. Mesure avant + manifeste (toujours écrit, même en dry-run) ----------
$probe = @'
set -u
NOW=$(date -u +%s)
REF_MAIN=$(date -u -d "@$((NOW - 3600*MAINH))" '+%Y-%m-%d %H:%M:%S')
REF_KERN=$(date -u -d "@$((NOW - 3600*KERNH))" '+%Y-%m-%d %H:%M:%S')
REF_AUD=$(date -u -d "@$((NOW - 3600*AUDH))" '+%Y-%m-%d %H:%M:%S')
MAN=/opt/data/prune-manifest-$(date -u +%Y%m%dT%H%MZ).txt
: > "$MAN"
size() { du -sm "$1" 2>/dev/null | cut -f1; }
S_BEFORE=$(size /opt/data/cache/scratch)
A_BEFORE=$(size /opt/data/audit-17073)
echo "scratch_before_mb=$S_BEFORE audit_before_mb=$A_BEFORE"
echo "refs main=$REF_MAIN kernel=$REF_KERN audit=$REF_AUD"
# scratch : non-hermes_*
cd /opt/data/cache/scratch 2>/dev/null && for e in * .[!.]*; do
  [ -e "$e" ] || continue
  case "$e" in hermes_*) continue;; esac
  [ "$e" -nt "$REF_MAIN" ] && continue
  echo "/opt/data/cache/scratch/$e" >> "$MAN"
done
# scratch : entités hermes_* (kernels/sockets)
for e in hermes_*; do
  [ -e "$e" ] || continue
  [ "$e" -nt "$REF_KERN" ] && continue
  echo "/opt/data/cache/scratch/$e" >> "$MAN"
done
# audit
cd /opt/data/audit-17073 2>/dev/null && for e in * .[!.]*; do
  [ -e "$e" ] || continue
  [ "$e" -nt "$REF_AUD" ] && continue
  echo "/opt/data/audit-17073/$e" >> "$MAN"
done
echo "manifest=$MAN entries=$(wc -l < "$MAN")"
'@

$probe = $probe.Replace('MAINH', $MainHours).Replace('KERNH', $KernelHours).Replace('AUDH', $AuditHours)
$probePath = Join-Path $env:TEMP ("hermes-cache-probe-{0}.sh" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
[System.IO.File]::WriteAllText($probePath, ($probe -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

try {
    $out = & docker cp $probePath 'hermes:/tmp/prune-probe.sh' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker cp a échoué : $out" }
    $measure = & docker exec -u hermes -e HOME=/opt/data hermes sh /tmp/prune-probe.sh 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sonde en échec : $measure" }
} finally {
    Remove-Item $probePath -Force -ErrorAction SilentlyContinue
}

$measure | ForEach-Object { Write-Log ("  " + $_) }
$entriesLine = ($measure | Where-Object { $_ -match '^manifest=' } | Select-Object -Last 1)
if (-not $entriesLine -or $entriesLine -notmatch 'entries=(\d+)') {
    Write-Log 'ABORT - manifeste non produit (rien supprimé)'
    exit 1
}
$entryCount = [int]$Matches[1]
$manifestPath = ($entriesLine -replace '^manifest=', '' -replace ' entries=.*$', '')

if ($entryCount -eq 0) {
    Write-Log 'OK - rien à élaguer (toutes les entrées sont plus fraîches que les seuils)'
    exit 0
}

if (-not $Apply) {
    Write-Log ("DRY-RUN - {0} entrées éligibles, rien supprimé (manifeste {1})" -f $entryCount, $manifestPath)
    exit 0
}

# --- 3. Suppression bornée ---------------------------------------------------
$del = @"
set -u
MAN=$manifestPath
BUDGET=$MaxDeleteGB
TOT=0; N=0; STOPPED=0
while IFS= read -r p; do
  [ -e "\$p" ] || continue
  SZ=\$(du -sm "\$p" 2>/dev/null | cut -f1); SZ=\${SZ:-0}
  if [ \$((TOT + SZ)) -gt \$((BUDGET*1024)) ]; then STOPPED=1; break; fi
  rm -rf -- "\$p" && { TOT=\$((TOT + SZ)); N=\$((N + 1)); }
done < "\$MAN"
echo "deleted_entries=\$N deleted_mb=\$TOT budget_hit=\$STOPPED"
S_AFTER=\$(du -sm /opt/data/cache/scratch 2>/dev/null | cut -f1)
A_AFTER=\$(du -sm /opt/data/audit-17073 2>/dev/null | cut -f1)
echo "scratch_after_mb=\$S_AFTER audit_after_mb=\$A_AFTER"
df -m /opt/data | tail -1 | awk '{print "volume_used_mb="\$3" volume_free_mb="\$4}'
"@
$delPath = Join-Path $env:TEMP ("hermes-cache-del-{0}.sh" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
[System.IO.File]::WriteAllText($delPath, ($del -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
try {
    $cp = & docker cp $delPath 'hermes:/tmp/prune-del.sh' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker cp (del) a échoué : $cp" }
    $result = & docker exec -u hermes -e HOME=/opt/data hermes sh /tmp/prune-del.sh 2>&1
    if ($LASTEXITCODE -ne 0) { throw "suppression en échec : $result" }
} finally {
    Remove-Item $delPath -Force -ErrorAction SilentlyContinue
}
$result | ForEach-Object { Write-Log ("  " + $_) }
Write-Log 'DONE'
