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
- l'**inbox RooSync du siège** : `roosync_messages(action: "inbox", status: "unread")` — ne traiter QUE les messages adressés à `myia-ai-01:hermes-agent` (les `[MENTION]` adressés à `myia-ai-01` seul appartiennent aux autres lanes : ne pas y toucher). Le bot ne peut PAS lire ces messages (derrière le proxy il sert l'inbox `myia-ai-01:roo-extensions`) : toute TASK de re-review / re-réponse adressée au siège se traite côté harnais (poster sous clusterManager-Myia via le `gh` du conteneur, `env -u GH_TOKEN`), puis répondre au DM et le marquer lu. Précédent 19/10 : TASK c2190, 3 re-reviews posées.

Identifie : le dernier `[STATUS 3h]`, les réponses à tes `[ASK]` (nanoclaw, claudish), les réponses user, les TASK en attente dans l'inbox du siège.

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
   boucle de répétition, filtre de contenu).
   **La TAILLE ne classe pas (mesuré 27/10)** : un rapport `RUN-ERROR` pèse 8-12 k car., exactement comme un
   rapport sain — le pr-review `08:41:33` (11 043 car.) a été déclaré « sain » sur sa seule taille au fire 08:53Z,
   puis flaggé par le watchdog à 09:11Z. Classer sur la **queue** de chaque rapport (`## Error` / exception,
   ligne `Response Characters`, marqueur d'abort 181 car., fin en résultats web bruts), jamais sur le poids.
   Corollaire : le watchdog saute un rapport modifié dans les 2 dernières minutes ; un rapport vu au fire N peut
   n'être verdicté qu'au tick N+1 — ne pas conclure « sain » sur un rapport tout frais sans avoir lu sa queue. Le watchdog cron-output les signale (`SEARCH-DUMP`, `RUN-ERROR`)
   depuis le 15/10 ; avant, il en était aveugle (5 échecs sur 14 runs en 3 h, log « OK »). Cause d'une rafale :
   croiser d'abord avec le hub (cascade, `[Failover]`) — c'est l'amont qui forme ces réponses. Un `RUN-ERROR`
   « HTTP 400 … Cannot reach GLM Coding at `https://api.z.ai` » vient du HUB (le bot appelle bien `192.168.0.50:3000`) :
   le hub n'a pas joint z.ai et répond 400, que le client ne rejoue pas (1er cas 15/10 23:06Z, flap hub 23:08Z).
   **QUOTA 5 h DU RÔLE `sonnet` (mesuré 27/10, distinct des deux précédents)** : la signature est
   `HTTP 429 … anthropic.RateLimitError: Usage limit reached for 5 hour. Your limit will reset at <horodatage>`
   — 28 occurrences entre 07:15Z et 17:47Z, avec **7 runs sur 14 en échec (50 %)** sur la fenêtre 14:40→17:53Z,
   les trois lanes tombant **ensemble** (17:20/17:21/17:34). Ne pas la confondre avec un mur GLM (PAYG) ni avec
   un flap hub : ici le provider derrière le rôle est épuisé **pour plusieurs heures**, donc chaque run qui tombe
   dedans meurt et son bilan est perdu — ce n'est pas auto-réparable avant l'heure de reset annoncée. Gratter
   l'horodatage avec `grep -oE "Usage limit reached for [^\"]*" /opt/data/logs/agent.log | tail -1` et l'annoncer.
   **PIÈGE UTC+8 (corrigé 27/10 soir par claudish, confirmé au log)** : l'horodatage de reset du message est en
   **UTC+8**, pas UTC — « 2026-10-28 02:45:56 » voulait dire **18:45:56Z le 27/10** (déjà passé quand on l'a lu).
   Convertir avant d'annoncer une durée, et recouper : `grep -E "^2026-…:.*Usage limit reached"` timestampé —
   zéro ligne après l'heure de reset convertie = mur levé. Distinguer aussi le **429 par requête** (« Rate limit
   reached for requests », sans « Usage limit ») : autre limite (RPM du PAYG), même code HTTP — classer sur le
   texte, pas sur le code.
   Un run peut aussi survivre : `API call #2` après un 429 = le client rejoue et progresse → lire `agent.log`,
   ne pas conclure du seul rapport d'erreur. Corroboration indépendante utile : les
   `[ERROR] Condensation truncation fallback` de la machine tombent dans la même fenêtre (organe distinct, même amont).
   **Runs longs = hub lent, pas blocage** (mesuré 19/10 : pr-review 08:35Z encore en vol à 10:36Z, appels API à
   7–11 min de latence et 37–48 k tokens de sortie ; audit 08:50Z → 10:37Z, 1 h 47). Avant de suspecter un gel :
   `last_dispatch.dispatched_at` récent ET `fire_claim` qui bat = run vivant ; confirmer dans
   `/opt/data/logs/agent.log` (`API call #N … latency=…`). Les `already running — skipping` des slots suivants
   sont bénins — moins de rapports que de slots n'est pas une panne en soi.
   **Refus partiel non masqué (mesuré 26/10 05:44Z)** : le pr-review 05:44Z rapporte 5/5 avec un avertissement
   terminal `File-mutation verifier: 1 file edit(s) FAILED` — `write_file /tmp/review_22622.txt` refusé
   (`HERMES_WRITE_SAFE_ROOT` = `/opt/data` seul). Le bot a utilisé un autre chemin et posté ses reviews.
   À signaler quand présent ; non bloquant si les reviews sont effectivement postées (vérifier au sol).
   **Hub en cascade** : le 26/10 au matin le rôle Sonnet de ce siège est servi en fallback (GLM GLM-4.7
   épuisé → Kimi k3.1-pro) — l'expérience 15/10 (« les étapes de repli forment moins bien les appels d'outils »)
   s'applique : si une rafale THREAD-FAIL réapparaît, croiser avec le hub AVANT d'incriminer le prompt.
4. **Reviews postées** (hôte) : les reviews du bot, plus récentes d'abord, tous dépôts, en UN appel :
   `gh api graphql -f query='query { user(login:"clusterManager-Myia") { contributionsCollection { pullRequestReviewContributions(first: 100, orderBy:{direction: DESC}) { nodes { pullRequestReview { submittedAt state body commit { oid } } pullRequest { number repository { nameWithOwner } } } } } } }'`
   Instrument versionné : `python roosync-cluster/scripts/check-review-bodies.py <ISO du fire précédent>`
   (exit 1 si doublon, corps court ou littéral ; avertit si la page de 100 ne remonte pas jusqu'au since).
   NE PAS passer par `search/issues` trié par `updated` : une vague de mises à jour CoursIA (des dizaines de
   PRs en quelques secondes) chasse les reviews fraîches de la fenêtre. Au moins une review récente doit
   porter `[Hermes` (NanoClaw poste sous le même compte avec `[NanoClaw`).
   **QUATRIÈME CÉCITÉ (corrigée 25/10 23:30Z, commit `d742a34274`)** : le marqueur `[Hermes` n'est pas un champ
   d'API, c'est un **format de sortie que le modèle peut reformuler**. Mesuré sur 21:09→22:46Z : trois en-têtes
   vivants — `[Hermes] Review…`, `## Review Hermes (lane myia-ai-01:hermes-agent)…`, `## Review Hermes — incrémentale…`.
   Seul le premier matchait : une lane qui poste 5 reviews/cycle lisait **0 review** sur 3 h. Deux faits mesurés qui
   s'additionnent — (a) la fenêtre GraphQL de 100 contributions est saturée par les DEUX bots (~45 reviews/3 h) et
   sa part CoursIA était figée au **24/10 07:49Z** alors que roo-ext/mcp-servers restaient frais (22:59Z) : la 3ᵉ
   cécité domine, la dérive de marqueur masque ce qui remonte ; (b) **les PR mergées ne sont PAS évincées de cette
   vue** (26 MERGED parmi les 100) et #22582 est **open**, pas mergée — une première hypothèse « mergée ⇒ sortie de
   la vue » a été testée et réfutée, ne pas la recopier. Depuis, les DEUX organes
   (`check-review-bodies.py` et `hermes-review-watchdog.ps1`) partagent le même prédicat : accepter `[Hermes`
   n'importe où OU un corps commençant `## Review Hermes`, en **excluant un corps dont la 1ʳᵉ ligne commence
   `**[NanoClaw`** — ancré première ligne, car une review Hermes incrémentale CITE l'analyse NanoClaw qu'elle
   prolonge (#22582 22:44:42Z). Preuve : 10/10 reviews réelles classées juste, 5/5 cas de parité, dry-run OK.
   Ne jamais conclure « 0 review » sur le seul instrument : vérifier au sol par REST avant d'escalader.
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
   **INSTRUMENTS AVEUGLES (mesuré 23/10)** : ni `gateway_state.json` ni `docker logs` ne disent la vérité ici.
   (a) `gateway_state.json` est resté figé au **14/10 11:18:32Z** (`updated_at`, `writer_pid 171`) et ne liste que
   `platforms: ['api_server']` **alors que Telegram tournait** — le fichier n'est pas réécrit sur ce siège : une
   absence de clé `telegram` n'est PAS une preuve de non-connexion (le `[FAIL] Telegram state — unknown` de
   `hermes-restore.ps1` vient de là). (b) `docker logs hermes` ne montre **aucune** ligne d'adaptateur : s6
   redirige la sortie du service vers des fichiers. **Le seul instrument qui voit** = `gateway.log` :
   `docker exec -u hermes -e HOME=/opt/data hermes sh -c 'grep -niE "connecting to telegram|telegram connected|Gateway running with|polling confirmed healthy" /opt/data/logs/gateway.log | tail -8'`
   → attendu `Connecting to telegram...`, `[Telegram] Telegram polling confirmed healthy`, `✓ telegram connected`,
   `Gateway running with 1 platform(s)`. Contrôle amont (config résolue, pas la config sur disque) : charger
   `load_gateway_config_for_runner()` dans le conteneur après `load_hermes_dotenv` et vérifier
   `platforms[TELEGRAM].enabled = True`.
6. **Bus RooSync (capabilité)** : dernier write du BOT (`myia-ai-01|hermes-agent` hors posts harnais
   `[STATUS 3h]`) sur `workspace-cluster-coordination`. Lire ce que disent les bots (Hermes + NanoClaw) :
   regex `bus down|undelivered|fallback|write failed|no dashboard|MCP.*down|recovery|downgrad`.
7. **Ressources** (ai-01 = machine la plus chargée de la flotte) : RAM libre, `docker stats --no-stream hermes`.

## Mise en place (avancer d'un cran à chaque fire, puis le consigner)

État courant tenu dans le post `[STATUS 3h]` (cases à cocher). Prends le premier item actionnable non
bloqué ; ne force jamais un item bloqué (le noter avec sa condition de reprise).

- [x] **Audit des backups planifiés d'ai-01 (mandat user, fire 04:53Z 24/10)** — lecture seule, posté sur
      `workspace-nanoclaw` (`hermes-audit-nanoclawbackup-20261024T0453Z`). Les 3 tâches existent ; mesure :
      · `NanoClawBackup` : `LastTaskResult=1` **mais le log dit réussi** (101 DB, 79 Mo, `integrity: all ok`,
      7 snapshots, prune OK) — **faux rouge** (l'`exit 1` vient d'après le travail, sous `$ErrorActionPreference='Stop'`) :
      un rouge qui ment dans le sens rassurant masquera le vrai. Destination `E:\nanoclaw-backups` = **disque LOCAL
      d'ai-01** (`DisplayRoot` vide) → protège de la corruption, **pas de la perte de machine** (le scénario du mandat).
      · `RSM-backup-mcp-env-daily` : 0x0, dernier 23/10 09:17, prochain 24/10 09:17 (volet roo-extensions, rien à mesurer de plus ici).
      · `OWUI-Tenants-Backup-Weekly` : 0x0, dernier 18/10, prochain 25/10 03:15 ; `backups\owui-daily\` contient des
      **sous-dossiers datés** (2026-10-18, 10-11, 10-05) — un `Get-ChildItem -File` y rend vide à tort, vérifier en `-Directory`.
      **Règle générale confirmée** : pour un backup, mesurer (a) le code de sortie, (b) le log du travail, (c) la TAILLE
      et le CONTENU produit, (d) la LOCALISATION (même machine = ne couvre pas la perte machine). Les quatre peuvent
      diverger — c'est arrivé sur deux lanes le même jour.
- [x] **Backup GDrive ciblé (mandat user 23/10, commit `425cce8d7c`)** : `hermes-backup-essentials.ps1` —
      passe essentielle (memories/SOUL/skills/config/`.env*`/jobs.json, ~1 Mo gz, rotation 14) ; le dimanche UTC
      ajoute `-Weekly` (state.db gz ~226 Mo, rotation 4). Destination `G:\Mon Drive\Synchronisation\RooSync\hermes-backups\`.
      PAS de tars volumineux (parole user). **DÉCLENCHEUR PÉRENNE DEPUIS 25/10 23:45Z** : tâche Windows
      `Hermes-GDrive-Backup` (quotidienne 01:53 locale, `StartWhenAvailable`, non élevée, lanceur VBS caché),
      script `hermes-gdrive-backup-daily.ps1`, log `roosync-cluster/logs/gdrive-backup.log`. **Ne plus déclencher
      la passe au fire 01:53Z** : le cron harnais dérive de minute à chaque réarmement (:53→:33→:24 mesuré le 25/10),
      donc la passe quotidienne avait silencieusement cessé (dernière archive 05:54Z avant rattrapage 23:40Z) — un
      backup ne doit jamais dépendre de la minute où tombe un cron. Vérifier à chaque fire : archive essentials la
      plus récente < 26 h ET log `OK produced` (un code de sortie seul peut mentir dans les deux sens), plus
      `Get-ScheduledTaskInfo Hermes-GDrive-Backup` `LastTaskResult=0x0` ET **`NextRunTime` non NULL**
      (leçon 26/10 : le template initial était un `<TimeTrigger>` à tir unique — premier tir réussi,
      `NextRun` NULL après, demain sans backup ; corrigé en `<CalendarTrigger><DaysInterval>1</DaysInterval>`,
      commit `700acc5a65`. Un organe fraîchement déployé se vérifie sur **le tir N+1 prévu**, pas sur le
      premier tir réussi). Le dimanche, vérifier aussi l'archive state.
      Bonus trouvé en déployant : le shim boot 012 produisait des archives VIDES de 155 o depuis le 14/10
      (corrigé en 014, effectif au prochain rebuild).
- [x] **Telegram — FAIT 23/10 23:21Z** (commit de la présente routine). Token posé par l'user dans
      `roosync-cluster/config/.env.secrets` → copié sur le volume → `hermes-restore.ps1` (23 PASS / 4 FAILED,
      dont `Telegram state — unknown` = instrument aveugle, cf. check 5) → **gateway connecté** :
      `gateway.log` 23:20:55Z `Connecting to telegram...`, 23:21:07Z `polling confirmed healthy` +
      `✓ telegram connected`, 23:21:09Z `Gateway running with 1 platform(s)`, 60 commandes enregistrées.
      Preuve de bout en bout hors gateway : `getMe` → `@MyIAHermesBot`, `sendMessage` → `message_id 24500`
      dans `-1003904676273`. Les **5 jobs** sont repointés `--deliver telegram:-1003904676273` et
      `hermes-morning-brief` est **réactivé** — 1er tir **livré** 24/10 08:09:22Z (`message_id=24551`) :
      les 5 jobs ont tous livré au moins une fois, le montage est complet. **Livraison de job PROUVÉE** 23:37:47Z :
      `agent.log` → `Job 'hermes-ping-intercom-ai01': delivered to telegram:-1003904676273 via live adapter
      thread=- message_id=24504`. Marqueur à grepper : `delivered to [a-z]+:` / `Delivery failed for job`
      (`cron/scheduler_delivery.py:1839` / `:3174`) — **pas** le mot « deliver » seul, la ligne de boot
      « Secret redaction … before delivery » est un faux positif (mesuré). `[SILENT]` supprime la livraison
      (`cron/scheduler.py:559`), donc un run muet n'est pas un échec.
      Pourquoi le 14/10 c'était resté `local` : sans credentials le preflight du scheduler BLOQUE tout job livré
      sur Telegram avant de lancer l'agent — `Status: BLOCKED (configuration)`.
- [x] Jobs bot repris un par un après validation : pr-review, ping-intercom, cluster-tour (14/10). morning-brief
      réactivé le 23/10 avec la livraison Telegram.
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
      **Fire 19:53Z :**
      - Le cycle 53 (17:57Z) a de nouveau posté un commentaire littéral `@comment21127.md` (`gh api -f body=@…`). Le bot
        l'a supprimé lui-même ; 404 vérifié.
      - Le prompt n'interdisait `-f body=@` que pour le PATCH de la checklist, pas pour le POST du commentaire. Ajout
        après « UN commentaire sur l'issue de SÉRIE » : poster avec `-F body=@comment.md`.
      - Sémantique mesurée sans effet de bord sur `POST /markdown`, avec le `gh` de l'hôte et celui du conteneur :
        `-F` lit le fichier, `-f` publie le littéral.
      - Live via `update_job`, seul `prompt` changé (5864 → 6060), sauvegarde `cron/jobs.json.bak-20261016T2000Z`.
      - **Écart source/live trouvé** : `roosync-cluster/prompts/hermes-notebook-audit.prompt.md` n'avait pas reçu le
        changement « Compression » de 05:00Z. La source est réalignée sur le live.
      - Règle : toute édition live d'un prompt met à jour sa source dans le même geste.
      - À vérifier aux cycles suivants : plus de littéral `@…` dans les commentaires d'audit (`check-review-bodies.py`
        ne voit que les reviews).
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
- [x] Watchdogs hôte (review, cron-output, MCP) remappés `C:\Users\jsboi` → `C:\Users\MYIA` (Phase 2 — **TICKÉ au fire 22:33Z 22/10** :
      les TROIS sont enregistrés sur ai-01 et verts à chaque fire (`Hermes-Review-Watchdog`, `Hermes-CronOutput-Watchdog`,
      `Hermes-ClusterTour-Watchdog`, `LastTaskResult=0x0` mesuré à chacun depuis le 16/10) ; le watchdog MCP reste
      volontairement NON enregistré (décision tranchée 16/10, cf. infra). Plus aucun cran de mise en place ici.
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
      **MOTIF RÉVISÉ 24/10 — ce n'est pas la fenêtre de midi, c'est la CASCADE** : 3 tournées consécutives
      MISSING par **THREAD-FAIL avant post** (12:13Z 22/10, 12:13Z 23/10, **00:13Z 24/10** — cette dernière
      ROMPT le résumé « 00:13Z saine »). Corps du rapport 24/10 : réponse finale « T#179 … I'm on T#180.
      Posting to global. » suivie de l'abort 181 car. — mort en ÉTAPE 3 avant l'append, recorded `ok`.
      Le bon prédicteur n'est pas l'heure du fire mais **l'état de la cascade hub au moment du dispatch** :
      la nuit 24/10 00:05-00:15Z avait vLLM timeout socket-held, deepseek-v4-flash 200-vide, claude-sonnet-5-5
      429 (reset 08:39Z), frognano 403 — le notebook-audit 00:12:56Z est mort de la même signature dans la
      même fenêtre. Les étapes de repli du hub forment mal les 24 outils. Cause racine du hub = correctif
      confié à po-2023 (Refs #28) ; tant qu'il n'est pas déployé, chaque fire sous cascade est exposé.
      À chaque fire qui suit un tour : lire le verdict du watchdog ET le corps du rapport ; si MISSING,
      poster la cause mesurée (répondre au WARN — fait 24/10 01:53Z, `tour-missing-0013-20261024-rootcause`,
      crossPost Maintenance qui avait testé le bus) — ne JAMAIS re-firer (spec). T#180 sauté, le prochain
      tour repart sur T#180.
      **Point de données 25/10 00:13Z = OK** (T#184 posté 00:37:39Z, verdict watchdog OK, ok=15) alors que
      deux THREAD-FAIL avaient frappé le bot à **22:17Z et 22:25Z** la même soirée. À lire comme une
      précision du prédicteur, pas comme une contradiction : ce qui expose un tour est l'état du hub
      **dans la fenêtre de son propre dispatch**, pas quelques heures avant — deux aborts en début de
      soirée ne présagent rien d'un tour deux heures plus tard, et symétriquement une soirée calme ne
      protège pas (cf. 00:13Z 24/10 tombé sur une nuit saine par ailleurs). Ne pas extrapoler d'un
      voisinage temporel : constater le hub à T-10 min, ou accepter le risque et répondre causalement
      si MISSING.
      **Watchdog MCP : NON enregistré, décision tranchée au fire 16:36Z (mesures dans le runbook, Phase 2).**
      (1) Le code de l'image ne laisse plus mourir un pont : après 5 échecs, et dès l'échec de la 1re connexion,
      il parque le serveur et le resonde toutes les 300 s (`_park`, lu dans le code ; 0 parcage dans les logs du
      bot depuis le 14/10). (2) Son Stage 1 cherche `hermes gateway run`, qui ne correspond à aucun processus ici :
      il irait droit à `docker restart`. (3) L'angle mort « pont vivant, backend mort » est couvert par
      `MCP-Chain-Healthcheck` et le check 6. **Tour de 00:13Z CONTRÔLÉ (fire 01:53Z, 17/10) : PENDING à 00:19Z puis OK
      à 00:49Z, `ok` 2→3 — le correctif PENDING se comporte comme prévu sur son premier cycle réel.**
      **Tour de 12:13Z 17/10 CONTRÔLÉ (fire 13:53Z) : PENDING à 12:19Z puis OK à 12:49Z, `ok` 3→4 — 2e cycle réel
      conforme (T#170 posté 12:16:29Z ≥ fire 12:13:34Z).** Fire 04:52Z :
      conteneur toujours up depuis 23:19Z, parade vérifiée en place (`agent:` < `auxiliary:`), restore identique.
      **Panne provider api.z.ai 03:23–03:59Z** (HTTP 400 via le hub, classe documentée) : 4 RUN-ERROR (pr-review ×2,
      ping-intercom, notebook-audit), résorbée au run 04:05Z. Non silencieuse, documentée par le bot (INCIDENT 04:23Z),
      sous le seuil (d) — pas d'escalade. Aucune récidive du `list index out of range` (01:47Z isolé).
      **19/10 22:5xZ : 403 déterministes sur `/user` du review-watchdog** — tous les ticks `:37` ont échoué
      (18:37→22:37, 5/5) pendant que tous les `:07` passaient : le single-shot perdait un tick sur deux. Correctif :
      retry 3×20 s sur la résolution du login + corps de la réponse 403 loggé (le JSON de GitHub dit POURQUOI :
      rate limit / abuse / auth). Parse PS 0 erreur, dry-run vert (`state not written`). **À vérifier aux fires
      suivants : les ticks `:37` passent** (OK direct ou retry puis OK) ; le corps 403 loggé à la première récidive
      tranche la cause (corrélation :37 à élucider — rien dans le script ne distingue :07 de :37).
      **Vérifié fire 01:53Z 20/10 : OK** — 23:37Z et 00:37Z verts d'emblée, 01:37Z 403→retry 20 s→vert : le correctif
      sauve le tick. Le corps 403 est VIDE (GitHub n'en fournit pas, ou le flux est déjà consommé sous PS 5.1) — la cause
      reste non élucidée mais l'organe est résilient ; item clos, re-ouvrir seulement si un tick :37 avorte aux 3 essais.
      **21/10 01:2xZ : tour 00:13Z = MISSING (missing=1), cause identifiée** : restart du **daemon Docker** à 00:31:31Z
      (machine PAS reboôtée — boot 19/10 00:02 ; RestartCount 0 ; les events Docker antérieurs ne survivent pas au
      restart du daemon). La tournée dispatchée à 00:13:29Z était encore en vol (hub nocturne lent) → tuée net :
      0 post, 0 `last_run` nouveau, 0 rapport (le cron-output-watchdog ne voit donc RIEN — il ne scanne que les
      rapports écrits ; seul le tour-watchdog a attrapé le manque, WARN posté sur global 00:49Z, posted=True).
      Pas de re-fire (spec). Boot de reprise sain : restore identique, identité gh OK, ponts 3/3/3 (correctif
      course-au-boot validé sur cas réel), cycle audit 148 posté 01:07Z. RAM hôte 9,1 Go après recharge des voisins.
      Leçon : un restart du daemon Docker tue les runs bot en vol SANS trace dans les rapports — croiser
      `State.StartedAt` du conteneur avec les `last_dispatch` sans `last_run` avant d'invoquer le bus ou le prompt.

- [x] **Course au boot MCP corrigée (fire 01:53Z, 17/10).** Au reboot machine du 16/10, le premier boot (21:12Z) a perdu
      la course : la sonde du restore (tir unique) partait avant que `myia-mcp-proxy` (même hôte) réponde → fallback
      local → **cassé sur ce siège** (aucun montage `/opt/roo-state-manager`, la copie `/tmp` échoue, `.env` jamais créé —
      INFO bot 21:54Z, tool_calls roosync_* en dégradé ~2 h, sauvé par le second boot 23:19Z qui a gagné la course).
      Correctif `hermes-restore-config.sh` : (1) la sonde retente 9×10 s ; (2) sans montage `/opt/roo-state-manager`,
      le script écrit les URLs distantes QUAND MÊME (le gateway parque un serveur MCP défaillant et le resonde toutes
      les 300 s — voir watchdog MCP ci-dessus) ; le fallback local ne reste que sur un siège qui porte le montage
      (po-2026). `bash -n` OK, copie volume redéployée identique (backup `restore-config.sh.bak-20261017T0200Z`).
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
- [x] **Parade `web_search` — LEVÉE le 18/10 13:4xZ (fire 13:39Z).** Historique : posée le 15/10 20:03Z
      (`agent.disabled_toolsets: [search]` dans le `config.yaml` du volume) après 5 pr-review finissant sur des
      résultats de recherche collés par l'amont ; mécanisme confirmé par ai-01:claudish (hub ne reconnaît que
      `WebSearch` exact, avale le `web_search` du bot, injecte le texte) ; correctif = PR claudish #498.
      **Condition de levée remplie 18/10** : #498 déployée sur le hub `443471b9` (déploiement clos claudish),
      preuve VERTE à la forme exacte d'Hermes (`tool_use` rendu sous le nom du client, 0 texte injecté —
      coordonnateur ai-01:claudish [DONE] 11:31Z sur workspace-claudish, lu firsthand), ACK de la lane
      cluster-tour du bot (12:18Z) renvoyant le geste à la lane harness.
      **Geste** : bloc retiré du `config.yaml` du volume (backup `config.yaml.bak-*-pre-search-lift`, YAML OK,
      `grep -c disabled_toolsets` = 0) + du seed `config.ai-01.yaml` + runbook mis à jour.
      **Test en cours** : les runs suivants doivent rester sans signature SEARCH-DUMP (le watchdog cron-output
      la détecte). **Rollback si récidive** : restaurer le bloc (backup ci-dessus), AU-DESSUS de la première
      ligne `auxiliary:` (le restore strippe tout à partir de là — règle de placement conservée au runbook).
      À chaque fire jusqu'à stabilisation : `grep -c disabled_toolsets config.yaml` = 0 ET 0 SEARCH-DUMP dans
      `cron-output-watchdog.log`.
- [x] Pré-audit (fil global vllm 17:19Z) : le bot n'a reçu AUCUN dossier `[nb-preaudit]` depuis le 14/10 (0 sur 824
      messages de l'inbox du siège, `/opt/data/tmp/preaudit/` vide). Demandé au producteur où il livre ; proposé
      `myia-ai-01:hermes-agent`. vllm a re-pointé son livreur (PR vllm#119, 15/10 23:2xZ) ; son probe
      `nbpre-probe-feb508221221` est bien arrivé dans l'inbox du siège (sha256 vérifié 16/10 ~02:00Z).
      **Mais le bot ne peut pas le lire** : via mcp-remote → proxy sparfenyuk d'ai-01, le serveur lui sert l'inbox de
      `myia-ai-01:roo-extensions` (860 messages, mesuré dans son spillover de 00:51Z), et ses DM sortants partent signés
      roo-extensions. Correctif = `as: "myia-ai-01:hermes-agent"` (#3591), qui exige `myia-ai-01` dans
      `ROOSYNC_TRUSTED_CALLER_IDS` (`D:\roo-extensions\mcps\internal\servers\roo-state-manager\.env`, aujourd'hui
      `myia-po-2026` seul) + relance `MCP-Proxy-RSM`. Infra roo-extensions : DEMANDÉ (global 16/10 ~02:00Z, crossPost
      roo-extensions). **RÉPONSE reçue 17/10 01:40Z (mention `ai01-c28-reply-hermes-trusted-callers-20261017`, lue au
      fire 13:53Z dans l'archive de condensation) : PAS APPLIQUÉ — escaladé à l'arbitrage user (RX105)** : ai-01 a
      qualifié l'ajout machine-seul `myia-ai-01` d'élargissement de permissions (la liste actuelle est machine-only) ;
      reco ai-01 = option (b) forme granulaire `machine:workspace`, qui nécessite une modif de code roo-state-manager.
      L'item est donc USER-GATED (RX105), plus « en attente roo-extensions » — ne pas re-demander à la lane.
      **Sur décision user RX105 (et modif code si (b))** : ajouter `as` aux appels inbox/send des prompts du bot
      (notebook-audit ÉTAPE 0.6 + C5), puis vérifier au cycle d'audit suivant. Backlog `Image/` : 0 dossier reçu après
      00:05Z et 01:05Z (signalé à vllm sur le même fil).
      **19/10 22:5xZ : RX105 DÉPLOYÉ par roo-extensions** (post 20:35Z sur workspace-hermes-agent :
      `ROOSYNC_TRUSTED_CALLER_IDS=myia-po-2026,myia-ai-01:hermes-agent`, sonde bout-en-bout : lane acceptée,
      machine-seule et autre workspace refusés, aucun restart). `as:` ajouté au prompt notebook-audit (ÉTAPE 0.6 inbox
      + C5 send) : source `prompts/hermes-notebook-audit.prompt.md` + live via `update_job` (backup
      `jobs.json.bak-20261019T2300Z-asparam`, seul `prompt` changé, vérifié). Le seed `jobs.bootstrap.json` ne porte
      pas ce prompt. **À vérifier au cycle d'audit suivant (23:50Z+)** : le bot lit l'inbox de la lane (30 non-lus
      annoncés par roo-extensions) sans erreur d'identité, et ses DM C5 partent signés hermes-agent.
      **Vérifié fire 01:53Z 20/10** : le run du cycle 126 (rapport `2026-10-20_00-04-33.md`, dispatch 23:50Z) porte le
      prompt avec `as:` ; l'ÉTAPE 0.6 a tourné sans rejet (un `as:` refusé par le serveur ferait échouer l'appel —
      l'entrée granulaire est acceptée). Preuve finale restante : le premier DM C5 envoyé par le bot, qui devra partir
      signé `hermes-agent` (à lire dans les sends du bus, pas dans le rapport).
      **20/10 19:5xZ : preuve finale ARRIVÉE — item CLOS** : le cycle 142 (MIMO-04, [DONE] 18:18Z) a envoyé son DM C5
      à myia-ai-01:vllm (« DM envoyé — canal preaudit silencieux depuis le 16/10, rien à proposer ») sans aucun rejet :
      le send avec `as:` passe. Nuance : le champ `from` du DM n'a pas été lu firsthand (il vit dans l'inbox vllm) —
      la preuve retenue est l'absence d'erreur RSM sur un send que le serveur aurait refusé si `as:` n'était pas accepté.
      **TICKÉ au fire 22:33Z 22/10 (côté SIÈGE)** : le volet siège est soldé (RX105 déployé + `as:` prouvé). Ce qui reste
      n'est PAS un cran du siège mais une **veille sur le producteur** : vllm ne livre aucun dossier `[nb-preaudit]`
      (0 sur ~830 messages de l'inbox du siège, `/opt/data/tmp/preaudit/` vide, constat répété à chaque cycle d'audit —
      les DONE récents disent « pas de dossier preaudit ce cycle »). Aucun geste possible ici : la livraison appartient
      à la lane vllm. Réouvrir seulement si un dossier arrive et qu'il n'est pas traité.
- [x] Attestation anti-dérive Z.AI claudish#81 (fire 04:30Z, 18/10) : scan complet du siège (`.env`, `.env.secrets` ×2,
      `config.yaml`, `~/.claude/settings.json`) → **aucune clé Z.AI directe**. Le seul identifiant nommé `GLM_API_KEY`
      (volume `.env` L18) porte la VALEUR de `CLAUDISH_PROXY_KEY` (fp sha256[:12] `6302afdcc061`, identique aux
      guillemets près) avec `GLM_BASE_URL` = hub `192.168.0.50:3000/v1` : c'est la clé proxy du hub, pas une clé Z.AI.
     Posté sur workspace-claudish (`attestation-81-hermes-ai01`). **Piège empreinte** : normaliser les guillemets avant
      sha256 — le même secret quoté/non-quoté donne 2 fp différents (`0bf54309e409` vs `6302afdcc061` mesuré).
- [x] Image : rebuild FAIT le 17/10 (fire 07:53Z→09:15Z) — `.env.example` maintenant LF dans l'image (0 CRLF mesuré,
      contre 554 avant). Séquence : fenêtre sans job en vol (attente active sur jobs.json) → backup réel
      `hermes-20261017-083538Z.tar.gz` (2 065 Mo, gzip OK, arrêt ~8 min — le volume a triplé depuis le 15/10) →
      `docker compose up -d --force-recreate` (gateway + dashboard). Vérifié : image `98ac6fd1b701`, sonde restore
      « reachable — using remote » au 1er essai, gateway 1, ponts 3×3, 0 parcage, 4 jobs enabled, et **la parade
      `search` a survécu au strip du boot** (`agent:` l.36 < `auxiliary:` l.62) — preuve réelle du correctif de
      placement. Rollback : `docker tag` inverse + compose force-recreate (étiquette `hermes-agent:ai-01-pre-rebuild-20261017`,
      ancienne `47f9aef78048`). Au fire suivant : premier tour complet de jobs sur la nouvelle image.
      **Fire 10:53Z : tour de jobs confirmé sur la nouvelle image** (7 rapports, 0 échec, 6 reviews propres, audit
      cycle 67 OK). **Incident dashboard** : le `--force-recreate` a réveillé `hermes-dashboard`, stoppé depuis avant
      le 16/10 — il bouclait (241 restarts en 1,8 h) : son boot rejoue le restore complet SUR LE VOLUME PARTAGÉ et meurt
      en cours de route (~45 s par passe, vraisemblablement bloqué sur le flock de `jobs.json` tenu par le scheduler du
      gateway). Stoppé (`docker compose stop dashboard`), puis **fencé par un profil compose** (`profiles: ["dashboard"]`
      dans `docker-compose.ai-01.yml`, commentaire expliquant) : un `up -d` futur ne le relancera plus. Le gateway n'a
      pas souffert (mitigation et jobs intacts à travers les 244 passes). Le conteneur stoppé reste en place (Exited).
      Fire 13:53Z : toujours Exited (137) 3 h, compose default = gateway seul — fence tient.
- [x] Dashboard web Hermes : `dashboard.basic_auth` — **SANS OBJET sur ce siège (fire 04:52Z, 17/10)** : `docker port
      hermes` = vide (le gateway ne publie rien) et le service dashboard de `docker-compose.ai-01.yml` est publié
      `127.0.0.1:9119:9119` — jamais joignable hors de l'hôte. Le flag `--insecure` de sa commande ne s'expose qu'en
      loopback. Réouvrir uniquement si le binding change.

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
- Cron harnais : <job ID>  ← **l'ID RÉARMÉ, pas le sortant** : faire le self-re-arm AVANT de poster le STATUS,
  pour que le post porte le bon ID en un seul message (les 8 fires du 25/10 ont tous posté l'ID sortant puis une
  [CORRECTION] — ordre inversé, corrigé ici). `CronList` affiche l'heure LOCALE (Paris = UTC+1 depuis le 25/10) et
  la minute du prochain tir est recalculée à chaque réarmement (dérive :53→:33→:24 mesurée) : citer l'ID et
  l'intervalle de 3 h, pas une heure absolue devinée.
```

## Escalade (UNIQUEMENT si)

PushNotification + `[WARN]` sur workspace-hermes-agent si l'une de :
- (a) conteneur down OU restart spiral (> 3 restarts sur la fenêtre)
- (b) pr-review actif mais aucune review `[Hermes` depuis > 4h — **mesurée au sol par REST, jamais sur la seule vue
  GraphQL contributions** (3ᵉ + 4ᵉ cécités : fenêtre de 100 saturée par les deux bots, part CoursIA figée, marqueur
  dérivé ; avant le 25/10 23:30Z l'instrument lisait « 0 review » sur une lane qui en postait 15)
- (c) bus MCP du bot down (patterns check 6, ou aucun write bot > 2h alors que les crons tournent)
- (d) > 30 % des runs bot en échec silencieux sur les 3 dernières heures
Sinon : PAS d'escalade.

## Self-re-arm (FIN, obligatoire)

Les CronCreate **expirent à 7j** ET **meurent à la fermeture de la session Claude Code** — mais PAS au reboot
machine/Docker : la session survit, et son cron avec elle (incident 19/10 01:54Z : deux reprises post-reboot ont
créé un cron chacune sans lister d'abord → **3 jobs identiques**, triple fire à venir, corrigé).
1. `CronList` → note le/les job ID(s) de surveillance existant(s). **Toujours, même sur une reprise.**
2. `CronDelete` de CHACUN (y compris celui qui te fait fire maintenant).
3. `CronCreate(cron: "23 */3 * * *", prompt: "/surveillance", recurring: true)`.
4. `CronList` → confirme exactement 1, et note le **nouveau job ID** dans le post `[STATUS 3h]`.
Il doit toujours y avoir **exactement 1** job de surveillance. **Signature du défaut : deux `/surveillance` à ~1 min
d'écart** — ne PAS réexécuter le cycle, faire CronList et nettoyer les surnuméraires.

## Fin de session

Restituer en bloc les questions ouvertes du registre user (`memory/user-question-registry.md`), dans le message
final ET en UNE entrée `[ASK-USER]` sur le dashboard `global` (vue consolidée du registre, ouvertes seulement,
format simple ; zéro ouverte = pas d'entrée — règle globale #4196). Une fois par jour suffit si le registre n'a
pas bougé depuis l'entrée précédente (les fires de 3 h sont des cycles d'une même session).
