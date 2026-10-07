# Command: /run-cron-task

**Workspace:** Hermes (opérateur Claude Code po-2026)
**Usage:** `/run-cron-task <slug>`

---

## Purpose

Exécuter la routine d'une tâche récurrente armée par `/fresh-task`. Wrapper mince : la **source de vérité** de chaque tâche est un doc dédié, relu à chaque exécution.

## Steps

1. Lis et exécute intégralement la routine dans `c:\dev\hermes-agent\.claude\cron-tasks\<slug>.md` :
   - Le corps de la tâche (objectif, vérifications, actions)
   - Le protocole de coordination Hermes qui l'accompagne (lecture intercom avant action, post résultat, self-re-arm)
2. **Self-re-arm** tel que spécifié dans le doc de la tâche : le cron porte cette commande (`prompt: "/run-cron-task <slug>"`) — le re-arm recrée le même CronCreate.
