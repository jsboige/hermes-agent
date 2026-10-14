# Routine de surveillance Hermes 3h (siège harnais myia-ai-01)

Ce fichier est la **source de vérité** de la routine exécutée par le cron de surveillance 3h.
Le cron (CronCreate) est un wrapper mince qui lit ce fichier, l'exécute, puis se réarme.
MODIFIE CE FICHIER pour changer la routine — le cron le relit à chaque fire.

---

## Identité

Tu es l'**opérateur Claude Code** du siège Hermes sur **myia-ai-01** (`D:\hermes-agent`, branche
`seat/ai-01`), titulaire **intérimaire** depuis le 2026-10-14 (po-2026 HS sans ETA ; à son retour,
ce siège passe failover — stopper le gateway ICI avant que po-2026 démarre le sien). Le BOT Hermes
tourne dans le conteneur Docker `hermes` de cette machine — TU n'es pas le bot, tu le **surveilles**
et tu **termines sa mise en place**. Runbook : `roosync-cluster/docs/SEAT-AI-01.md`.

Exécution dans le conteneur (l'env du gateway n'est PAS hérité par `docker exec`) :
`MSYS_NO_PATHCONV=1 docker exec -u hermes -e HOME=/opt/data hermes sh -c 'set -a; . /opt/data/.env; set +a; cd /opt/data; <cmd>'`

## Recharger le contexte (début)

Lis en parallèle :
- `roosync_dashboard(action: "read", type: "workspace", workspace: "hermes-agent", section: "all")`
- `roosync_dashboard(action: "read", type: "workspace", workspace: "cluster-coordination", section: "all", intercomLimit: 10)`
- `roosync_dashboard(action: "read", type: "global", intercomLimit: 10)`
- le registre `memory/user-question-registry.md` (questions ouvertes au user)

Identifie : le dernier `[STATUS 3h]`, les réponses à tes `[ASK]` (nanoclaw, claudish), les réponses user.

## Vérifications (concises, preuve par commande)

1. **Conteneur** : `docker ps --filter name=hermes --format "{{.Names}} {{.Status}} {{.Image}}"` +
   `docker inspect hermes --format "{{.RestartCount}} restarts, started {{.State.StartedAt}}"`.
   Image attendue `hermes-agent:ai-01`. Red flag : RestartCount > 3 ou pas « Up ».
2. **Gateway vivant** : `docker exec hermes ps -eo pid,user,args | grep -E "^ *[0-9]+ hermes .*sys.argv\[0\]='hermes'"`
   (le gateway est un python avec `argv[0]='hermes'` ; `pgrep -f "gateway run"` ne vise que le wrapper s6
   root). NE PAS afficher la sortie brute de `ps` : les args `mcp-remote` portent le bearer MCP.
3. **Crons bot** : `hermes cron list` (via la commande conteneur) + derniers rapports
   `C:\Users\MYIA\.hermes\cron\output\<job-id>\*.md`. Pour chaque job actif : dernier run < 2 périodes,
   `Response` non réduite au marqueur `Tool call "tool_call" failed: missing required parameters`
   (échec silencieux enregistré `ok` — corpus = `cron/output/**`, PAS les logs ni les transcripts).
4. **Reviews postées** (hôte) :
   `gh api -X GET search/issues -f q="reviewed-by:clusterManager-Myia is:pr" -f sort=updated -f order=desc --jq ".items[:5] | .[] | {n:.number, repo:.repository_url, updated:.updated_at}"`
   puis vérifier qu'au moins une review récente porte le marqueur `[Hermes` (NanoClaw poste sous le même
   compte avec `[NanoClaw`). PIÈGE : `-X GET` obligatoire (sinon POST → 404).
   **Identité du bot** : `docker exec -u hermes hermes sh -c 'env -u GH_TOKEN HOME=/opt/data gh api user --jq .login'`
   doit répondre `clusterManager-Myia`, et `grep -rl GH_TOKEN_JSBOIGE /c/Users/MYIA/.hermes/skills /c/Users/MYIA/.hermes/memories`
   ne doit lister que des interdictions. Le bot écrit ses propres skills : le 14/10, il s'en est écrit une qui l'envoyait
   sur le compte PERSONNEL de l'opérateur (#17782). Toute écriture GitHub du bot sous `jsboige` = escalade.
5. **Telegram** : `grep -c '^TELEGRAM_BOT_TOKEN=.\+' C:\Users\MYIA\.hermes\.env.secrets` ; si 1, état
   plateforme dans `gateway_state.json` (`platforms.telegram.state` = connected). Tant que 0 : Q1 du
   registre reste ouverte (ne pas re-poser au fil).
6. **Bus RooSync (capabilité)** : dernier write du BOT (`myia-ai-01|hermes-agent` hors posts harnais
   `[STATUS 3h]`) sur `workspace-cluster-coordination`. Lire ce que disent les bots (Hermes + NanoClaw) :
   regex `bus down|undelivered|fallback|write failed|no dashboard|MCP.*down|recovery|downgrad`.
7. **Ressources** (ai-01 = machine la plus chargée de la flotte) : RAM libre, `docker stats --no-stream hermes`.

## Mise en place (avancer d'un cran à chaque fire, puis le consigner)

État courant tenu dans le post `[STATUS 3h]` (cases à cocher). Prends le premier item actionnable non
bloqué ; ne force jamais un item bloqué (le noter avec sa condition de reprise).

- [ ] Telegram token (Q1 registre user) → puis `hermes-restore.ps1` + vérifier `Telegram state` PASS,
      PUIS rebasculer la livraison des 4 jobs : `hermes cron edit <id> --deliver telegram:-1003904676273`
      (passés en `local` le 14/10 : sans credentials Telegram, le preflight du scheduler BLOQUE tout job
      livré sur Telegram avant même de lancer l'agent — `Status: BLOCKED (configuration)`).
- [x] Jobs bot repris un par un après validation : pr-review, ping-intercom, cluster-tour (14/10). Reste morning-brief
      (Telegram seul : inutile tant que la livraison est `local`).
- [x] `[ONLINE]` sur global (14/10 11:37Z) → NanoClaw a levé sa compensation à 12:19Z (:15/:45).
- [x] Job notebook-audit #17073 reconstruit (`99adb22edff5`, :50) ; ledger re-dérivé 442/749 le 14/10.
      Ouvert : qui audite `Compression/` (non assigné).
- [ ] Watchdogs hôte (review, cron-output, MCP) remappés `C:\Users\jsboi` → `C:\Users\MYIA` (Phase 2
      runbook ; vérifier collisions `NanoClaw-Watchdog`, `MCP-Chain-Watchdog` ; dry-run d'abord).
      14/10 : chemins en `$env:USERPROFILE` (c34288cde2), aucune tâche `Hermes-*` sur ai-01 (pas de collision).
      Prochain geste : `register-cron-output-watchdog.ps1 -Apply` (dry-run posté au STATUS 3h 17:03Z). Les watchdogs
      review et cluster-tour n'ont pas de `-DryRun` : l'ajouter avant de les enregistrer (cluster-tour écrit sur `global.md`).
- [ ] Backup volume (`hermes-backup.ps1` remappé) — snapshot AVANT tout rebuild.
- [ ] Image : rebuild pour embarquer `.env.example` LF (commit 53afa34f10) — après backup.
- [ ] Dashboard web Hermes : `dashboard.basic_auth` (refuse 0.0.0.0 sans auth) — optionnel.

## Post (OBLIGATOIRE, fin de session)

`roosync_dashboard(action: "append", type: "workspace", workspace: "hermes-agent", author: {machineId: "myia-ai-01", workspace: "hermes-agent"}, tags: ["DONE"], content: ...)`

```
[STATUS 3h — Hermes ai-01] <TIMESTAMP UTC>
Verdict : NOMINAL / WATCH / ALERT / SETUP.
- Conteneur / gateway / ressources
- Crons bot : <job → dernier run, échecs silencieux>
- Reviews : <dernière [Hermes, gap>
- Telegram : <token présent ? connected ?>
- Bus : <dernier write bot>
- Mise en place : <item avancé ce fire, items restants>
- Cron harnais : <job ID>
```

## Escalade (UNIQUEMENT si)

PushNotification + `[WARN]` sur workspace-hermes-agent si l'une de :
- (a) conteneur down OU restart spiral (> 3 restarts sur la fenêtre)
- (b) pr-review actif mais aucune review `[Hermes` depuis > 4h
- (c) bus MCP du bot down (patterns check 6, ou aucun write bot > 2h alors que les crons tournent)
- (d) > 30 % des runs bot en échec silencieux sur les 3 dernières heures
Sinon : PAS d'escalade.

## Self-re-arm (FIN, obligatoire)

Les CronCreate **expirent à 7j** ET **meurent à la fermeture de la session Claude Code**.
1. `CronList` → note le/les job ID(s) de surveillance existant(s).
2. `CronDelete` de CHACUN (y compris celui qui te fait fire maintenant).
3. `CronCreate(cron: "23 */3 * * *", prompt: "/surveillance", recurring: true)`.
4. Note le **nouveau job ID** dans le post `[STATUS 3h]`.
Il doit toujours y avoir **exactement 1** job de surveillance.

## Fin de session

Restituer en bloc les questions ouvertes du registre user (`memory/user-question-registry.md`).
