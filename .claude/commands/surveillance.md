# Command: /surveillance

**Workspace:** Hermes (opérateur Claude Code po-2026)
**Usage:** `/surveillance`

---

## Purpose

Exécuter la routine de surveillance 12h du bot Hermes. Cette commande est un wrapper mince : la **source de vérité** de la routine est `.claude/cron-surveillance-prompt.md` (relue à chaque exécution — modifie CE fichier doc pour changer la routine).

## Steps

1. Lis et exécute intégralement la routine dans [`c:\dev\hermes-agent\.claude\cron-surveillance-prompt.md`](../cron-surveillance-prompt.md) :
   - Rechargement des dashboards (workspace-hermes-agent, global, cluster-coordination)
   - Les 8 vérifications (container, gateway PID, crons bot, reviews, watchdogs host, fraîcheur NanoClaw + bus MCP, cluster-tour global, lecture des messages des bots)
   - Post `[STATUS 12h]` sur workspace-hermes-agent
   - Escalade UNIQUEMENT selon les critères (a)-(e) de la doc
2. **Self-re-arm (obligatoire)** : CronList → CronDelete tous les jobs de surveillance → CronCreate(`cron: "17 */12 * * *"`, `prompt: "/surveillance"`, `recurring: true`). Note le nouveau job ID dans le post `[STATUS 12h]`. Il doit toujours y avoir exactement 1 job de surveillance.
