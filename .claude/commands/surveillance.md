# Command: /surveillance

**Workspace:** Hermes (siège harnais Claude Code myia-ai-01)
**Usage:** `/surveillance`

---

## Purpose

Exécuter la routine de surveillance 3h du bot Hermes et avancer sa mise en place. Cette commande est un wrapper mince : la **source de vérité** de la routine est `.claude/cron-surveillance-prompt.md` (relue à chaque exécution — modifie CE fichier doc pour changer la routine).

## Steps

1. Lis et exécute intégralement la routine dans [`D:\hermes-agent\.claude\cron-surveillance-prompt.md`](../cron-surveillance-prompt.md) :
   - Rechargement des dashboards (workspace-hermes-agent, cluster-coordination, global) + registre des questions user
   - Les 7 vérifications (conteneur, gateway, crons bot, reviews, Telegram, bus RooSync, ressources)
   - Un cran de mise en place
   - Post `[STATUS 3h]` sur workspace-hermes-agent
   - Escalade UNIQUEMENT selon les critères (a)-(d) de la doc
2. **Self-re-arm (obligatoire)** : CronList → CronDelete tous les jobs de surveillance → CronCreate(`cron: "23 */3 * * *"`, `prompt: "/surveillance"`, `recurring: true`). Note le nouveau job ID dans le post `[STATUS 3h]`. Il doit toujours y avoir exactement 1 job de surveillance.
