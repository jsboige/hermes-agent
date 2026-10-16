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
   Le boot rejoue `C:\Users\MYIA\.hermes\restore-config.sh` (copie volume) : elle doit être identique à
   `roosync-cluster/scripts/hermes-restore-config.sh` (`cmp` après `tr -d '\r'`). Le 15/10 elle avait un jour de
   retard (sans le correctif du login gh stocké `76da7974f1`) — inoffensif tant que le volume garde son
   `hosts.yml`, mais un volume neuf aurait perdu l'identité GitHub du bot.
2. **Gateway vivant** : `docker exec hermes ps -eo pid,user,args | grep -E "^ *[0-9]+ hermes .*sys.argv\[0\]='hermes'"`
   (le gateway est un python avec `argv[0]='hermes'` ; `pgrep -f "gateway run"` ne vise que le wrapper s6
   root). NE PAS afficher la sortie brute de `ps` : les args `mcp-remote` portent le bearer MCP.
3. **Crons bot** : `hermes cron list` (via la commande conteneur) + derniers rapports
   `C:\Users\MYIA\.hermes\cron\output\<job-id>\*.md`. Pour chaque job actif : dernier run < 2 périodes,
   `Response` non réduite au marqueur `Tool call "tool_call" failed: missing required parameters`
   (échec silencieux enregistré `ok` — corpus = `cron/output/**`, PAS les logs ni les transcripts).
   Classer TOUS les rapports depuis le fire précédent, pas seulement le dernier de chaque job : deux autres
   formes d'échec existent depuis le 15/10 — fin sur résultats bruts de recherche web (`N. **titre**` + URL
   indentée, enregistrée `ok`, aucun bilan ni STATUS) et section `## Error` avec traceback (`IndexError` du hub,
   boucle de répétition, filtre de contenu). Le watchdog cron-output les signale (`SEARCH-DUMP`, `RUN-ERROR`)
   depuis le 15/10 ; avant, il en était aveugle (5 échecs sur 14 runs en 3 h, log « OK »). Cause d'une rafale :
   croiser d'abord avec le hub (cascade, `[Failover]`) — c'est l'amont qui forme ces réponses. Un `RUN-ERROR`
   « HTTP 400 … Cannot reach GLM Coding at `https://api.z.ai` » vient du HUB (le bot appelle bien `192.168.0.50:3000`) :
   le hub n'a pas joint z.ai et répond 400, que le client ne rejoue pas (1er cas 15/10 23:06Z, flap hub 23:08Z).
4. **Reviews postées** (hôte) : les reviews du bot, plus récentes d'abord, tous dépôts, en UN appel :
   `gh api graphql -f query='query { user(login:"clusterManager-Myia") { contributionsCollection { pullRequestReviewContributions(first: 100, orderBy:{direction: DESC}) { nodes { pullRequestReview { submittedAt state body commit { oid } } pullRequest { number repository { nameWithOwner } } } } } } }'`
   Instrument versionné : `python roosync-cluster/scripts/check-review-bodies.py <ISO du fire précédent>`
   (exit 1 si doublon, corps court ou littéral ; avertit si la page de 100 ne remonte pas jusqu'au since).
   NE PAS passer par `search/issues` trié par `updated` : une vague de mises à jour CoursIA (des dizaines de
   PRs en quelques secondes) chasse les reviews fraîches de la fenêtre. Au moins une review récente doit
   porter `[Hermes` (NanoClaw poste sous le même compte avec `[NanoClaw`).
   Sur les reviews `[Hermes` depuis le fire précédent : 0 doublon au même `commit_id`, et aucun corps
   < 200 car. ni littéral `@/…` / `@fichier.md`. Le 14/10, un seul run (14:40→14:46Z) a posté 4 corps
   littéraux (#20432, #20656, #20634, #20602 — reposts 15/10 04:43Z) ; un contrôle des seuls doublons ne les
   voit pas, et un contrôle commencé après le run non plus.
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
- [x] `[ONLINE]` sur global (14/10 11:37Z, puis 17:02Z volet review seul). La cadence NanoClaw est SA décision :
      le 15/10 elle tenait encore les 4 créneaux (fires :03/:17/:31/:47 mesurés par NanoClaw 22:00→04:35Z) et son
      revert attend aussi Telegram. N'écrire « NanoClaw reverté » que sur un post signé NanoClaw qui le dit
      (T#165 l'a affirmé à tort, d'après un plan — règle ajoutée au prompt du tour le 15/10).
- [x] T#166 (15/10 12:13→12:17Z, 1er tour sous la règle « état étranger = mesuré ») : vérifié au fire 13:48Z —
      il cite ses sources (« NanoClaw tient les 4 créneaux, RAPPORTE lane nanoclaw 04:43Z », lanes « mesurées (posts
      signés…) VERIFIÉ »). Aux tours suivants, un état étranger sans source ni « prévu, non constaté » = régression.
- [x] Job notebook-audit #17073 reconstruit (`99adb22edff5`, :50) ; ledger re-dérivé 442/749 le 14/10.
      `Compression/` (2 notebooks : `Compression-01-ShannonFano-Prefixe-Python`, `Compression-02-HuffmanCanonique-Python` ;
      `Compression_lean/` sans `.ipynb`) est dans `meta.unassigned` du ledger, et le prompt du job dit « NON-ASSIGNÉ : ne
      pas auditer ». L'annexe de #17073 laisse les bots échanger la partition librement. `[PROPOSAL]` posté chez NanoClaw
      le 15/10 ~23:00Z (messageId `hermes-seat-compression-partition-20261015`) : Hermes les prend. **FAIT 16/10 05:00Z**
      (NanoClaw sans objection, cycle 04:45Z) : `Compression` ajouté à l'ensemble HERMES du prompt `99adb22edff5`, exemple
      retiré de la ligne NON-ASSIGNÉ, via `cron.jobs.update_job` dans le conteneur (verrou `jobs.json`), seul `prompt`
      changé (sauvegarde `cron/jobs.json.bak-20261016T0500Z`). Drift +2 publié sur #17073 (c.6209268462, 06:08Z) ;
      `unassigned 0` rapporté par le bot dès le cycle 08:18Z.
- [x] Tier âgé v1.1 → v1.2 dans le prompt pr-review (16/10 07:38Z, demande du bot INFO 06:07Z) : la spec v1.2 est
      mergée (roo-extensions #4218 ; #4215 fermée en doublon). Item 4 réécrit : pool sans plafond par
      `gh api …/pulls?state=open&sort=created&direction=asc&per_page=100`, total recoupé via `Link rel="last"`, pages
      croissantes jusqu'à la première éligible, ligne STATUS `pool N open, pages P` ; critères (a)(b)(c) et caps
      inchangés. Même texte dans le seed `jobs.bootstrap.json` (`restore-config.sh` ne régénère pas les prompts). Live
      via `update_job` dans le conteneur, seul `prompt` changé (`fire_claim` = battement du run 07:35Z en vol),
      sauvegarde `cron/jobs.json.bak-20261016T0738Z`. Le « `--limit 200` OBLIGATOIRE » cité par le bot n'était ni dans
      le prompt ni dans le volume (repris d'une REPLY de pair). Vérifié fire 10:53Z : le run 08:05Z porte le prompt
      v1.2 et écrit « pool 437 open recoupé » ; aucune promotion depuis (chaîne couverte), donc la forme `#N … pages P`
      reste à voir sur la première promotion.
- [ ] Watchdogs hôte (review, cron-output, MCP) remappés `C:\Users\jsboi` → `C:\Users\MYIA` (Phase 2
      runbook ; vérifier collisions `NanoClaw-Watchdog`, `MCP-Chain-Watchdog` ; dry-run d'abord).
      14/10 : chemins en `$env:USERPROFILE` (c34288cde2), aucune tâche `Hermes-*` sur ai-01 (pas de collision).
      `Hermes-CronOutput-Watchdog` enregistré le 14/10 19:34Z (non élevé, :11/:41 ; sans token Telegram il ne fait que
      journaliser dans `roosync-cluster/logs/`). `Hermes-Review-Watchdog` enregistré le 15/10 02:00Z (:07/:37,
      `register-host-watchdog.ps1 -Watchdog review`) ; il lit les reviews du bot en UN appel GraphQL (contributions,
      plus récentes d'abord) — tout échantillonnage par PR s'est aveuglé sur CoursIA. Vérifier à chaque fire :
      `review-watchdog.log` OK avec un âge cohérent avec le dernier `[STATUS Hermes pr-review]`, et
      `Get-ScheduledTaskInfo Hermes-*` LastTaskResult 0x0. 15/10 : cron-output étendu à `SEARCH-DUMP` et
      `RUN-ERROR` (dry-run PS 5.1 : 7 runs relevés, exactement les 7 manqués du jour, 0 faux positif sur 26 h). Watchdog cluster-tour : **enregistré le 16/10 11:01Z**
      (`Hermes-ClusterTour-Watchdog`, :19/:49, non élevé, dry-run posté avant). Son `[WARN]` passe maintenant par le
      bus (`roosync_dashboard append` en MCP/HTTP, idempotent par tour), plus par `Add-Content` sur `global.md` ; il
      lit aussi les archives de condensation postérieures au tour. 1er run manuel : `OK` (T#167), 0x0. **Fire 13:51Z :
      bug trouvé** — le tick de 12:19Z (PENDING) marquait le tour comme vérifié, celui de 12:49Z l'a donc sauté (SKIP) :
      le tour de 12:13Z n'a jamais été contrôlé. Corrigé (seuls OK/MISSING avancent l'état), testé sur sources jetables
      (PENDING n'avance pas, OK avance), état remis au tour de 00:13Z (sauvegarde `logs/…-state.json.bak-20261016T1400Z`),
      run réel : `OK` sur le tour de 12:13Z (titre à 12:17:13Z), `OkCount=2`. À chaque fire : le log doit montrer un
      `OK` ou `MISSING` pour chaque tour (00:13Z, 12:13Z), jamais un PENDING suivi seulement de SKIP.
- [x] Backup volume — 1er snapshot réel le 15/10 07:30Z : `C:\Users\MYIA\hermes-backups\hermes-20261015-073019Z.tar.gz`
      (546 Mo, gzip OK, 23 912 entrées dont state.db/config/SOUL/jobs/gh, sha256[:16] `0553dd73a0f6cdbf`), arrêt bot 148 s,
      teardown propre (0 job en vol, SessionDB fermée). Le ledger du gateway marque quand même la vie précédente
      « UNCLEANLY » : faux signal, le log montre le teardown complet. Fenêtre trouvée par attente active : fin d'un
      pr-review (07:30:08Z) → prochain fire 07:35Z. Refaire un snapshot avant chaque rebuild (`hermes-backup.ps1`).
- [x] Header `X-Claudish-Machine: myia-ai-01` (15/10 ~11:00Z) : `CLAUDISH_MACHINE` dans les deux `.env.secrets`,
      `restore-config.sh` le pose en `custom_providers[].extra_headers` (persiste au boot), inséré à chaud dans
      `config.yaml` (le cache de config suit la signature du fichier : pas de redémarrage). Résolu pour la route
      principale `http://192.168.0.50:3000` ; PAS pour la forme `/v1` (appels auxiliaires). Confirmé côté hub par
      ai-01:claudish (15/10 11:25Z) : 61/73 requêtes du bot portent `machine=myia-ai-01`, les 12 autres = un seul fil
      ouvert avant la pose ; aucune non attribuée après 11:16:57Z. Les appels auxiliaires (compression `glm-4.5-air`,
      provider `zai` → `GLM_BASE_URL` = hub `/v1`, clé = `CLAUDISH_PROXY_KEY`) restent SANS en-tête — rares (seuil
      202 752 tokens) ; 1 échec de compression 15/10 09:57Z (résumé tronqué `finish_reason=length`), non bloquant.
- [x] Alias `claude-sonnet-5-5` — ABANDONNÉ le 15/10 13:5xZ, on reste sur `claude-sonnet-4-6`. Réponse claudish
      (11:25Z) : l'abort 08:59Z venait de `deepseek-flash`, étape de cascade du rôle sonnet entier (GLM 402/429,
      Kimi 403 entre 08:24 et 09:19Z ; 0 réponse glm-5.3 sur 2 215 dans cette fenêtre). Les deux alias portent le
      mot-clé `sonnet` → même rôle, même cascade (SUPPOSÉ d'après `roleFromModelName()` ; la `modelMap` du hub fait
      foi). Changer de nom n'apporte rien de mesuré. « Ce siège ne cascade pas » est FAUX : il cascade quand GLM tombe,
      et les étapes de repli forment moins bien les appels d'outils (24 outils) → les aborts de ce siège suivront
      les fenêtres de cascade du hub. À la prochaine rafale d'aborts : croiser avec les `[Failover]` du hub.
- [ ] **Parade `web_search`** (15/10 20:03Z, `agent.disabled_toolsets: [search]` dans le `config.yaml` du volume,
      sauvegarde `config.yaml.bak-20261015T2003Z`) : 5 pr-review de suite finissaient sur des résultats de recherche
      collés par l'amont (74–95 tokens modèle pour 2,8–4,3 k car. reçus ; le bot n'exécutait aucun `web_search`).
      À chaque fire : pr-review revenu à des rapports normaux ? Retirer le bloc dès que claudish corrige ou explique
      le mécanisme (ASK 16:56Z + INFO 20:0xZ sur son dashboard). Détail : runbook, « Live-config mitigations ».
      Fire 22:53Z : la parade tient — 14 runs du bot depuis 19:53Z, 0 échec (4 pr-review, 24 reviews), 0 `web_search`.
      **Mécanisme confirmé par ai-01:claudish (15/10 23:30Z)** : le hub ne reconnaît comme outil client que `WebSearch`
      exact ; il supprime donc l'appel `web_search` du bot, exécute SearXNG lui-même, injecte le texte et clôt le tour.
      Correctif confié à po-2023 (Refs #28 du dépôt claudish). La parade reste « justifiée jusqu'au déploiement » :
      la retirer quand claudish annonce le déploiement, pas avant (ACK posté 16/10 ~02:05Z).
- [ ] Pré-audit (fil global vllm 17:19Z) : le bot n'a reçu AUCUN dossier `[nb-preaudit]` depuis le 14/10 (0 sur 824
      messages de l'inbox du siège, `/opt/data/tmp/preaudit/` vide). Demandé au producteur où il livre ; proposé
      `myia-ai-01:hermes-agent`. vllm a re-pointé son livreur (PR vllm#119, 15/10 23:2xZ) ; son probe
      `nbpre-probe-feb508221221` est bien arrivé dans l'inbox du siège (sha256 vérifié 16/10 ~02:00Z).
      **Mais le bot ne peut pas le lire** : via mcp-remote → proxy sparfenyuk d'ai-01, le serveur lui sert l'inbox de
      `myia-ai-01:roo-extensions` (860 messages, mesuré dans son spillover de 00:51Z), et ses DM sortants partent signés
      roo-extensions. Correctif = `as: "myia-ai-01:hermes-agent"` (#3591), qui exige `myia-ai-01` dans
      `ROOSYNC_TRUSTED_CALLER_IDS` (`D:\roo-extensions\mcps\internal\servers\roo-state-manager\.env`, aujourd'hui
      `myia-po-2026` seul) + relance `MCP-Proxy-RSM`. Infra roo-extensions : DEMANDÉ (global 16/10 ~02:00Z, crossPost
      roo-extensions), pas appliqué. **Sur leur oui** : ajouter `as` aux appels inbox/send des prompts du bot
      (notebook-audit ÉTAPE 0.6 + C5), puis vérifier au cycle d'audit suivant. Backlog `Image/` : 0 dossier reçu après
      00:05Z et 01:05Z (signalé à vllm sur le même fil).
- [ ] Image : rebuild pour embarquer `.env.example` LF (commit 53afa34f10) — après backup. Faible enjeu : ce fichier
      ne sert qu'à amorcer `.env` sur un volume NEUF (l'image en a 554 lignes CRLF ; le volume actuel n'est pas touché).
      Revérifié 15/10 23:00Z : arbre et index en LF (`git ls-files --eol` → `i/lf w/lf`), image en CRLF → le rebuild
      corrigerait bien. Mesurer les fins de ligne en Python (`b.count(b'\r\n')`) : sous Git Bash, `grep -c $'\r'` compte
      TOUTES les lignes. Aucun autre changement de code depuis le build (seuls `.gitattributes`/`.gitignore`) : à faire
      dans une fenêtre creuse de jour, pas de nuit pour ce seul motif.
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

Restituer en bloc les questions ouvertes du registre user (`memory/user-question-registry.md`), dans le message
final ET en UNE entrée `[ASK-USER]` sur le dashboard `global` (vue consolidée du registre, ouvertes seulement,
format simple ; zéro ouverte = pas d'entrée — règle globale #4196). Une fois par jour suffit si le registre n'a
pas bougé depuis l'entrée précédente (les fires de 3 h sont des cycles d'une même session).
