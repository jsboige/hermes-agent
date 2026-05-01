# RooSync Cluster — Custom Drift

This directory contains **cluster-specific customizations** for the hermes-agent fork.
It is isolated from the upstream codebase to facilitate future syncs.

## Structure

| Path | Purpose |
|------|---------|
| `docs/` | ADR, deployment guide, design documents |
| `scripts/` | Routing prototype and cluster utilities |

## Upstream Sync

```bash
git fetch upstream
git merge upstream/main
# Resolve conflicts in roosync-cluster/ if any (rare — upstream doesn't touch this dir)
```

## Related

- Upstream: [nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent)
- Fork: [jsboige/hermes-agent](https://github.com/jsboige/hermes-agent)
- Issue: #1862 (Hermes workspace bootstrap)
- EPIC: #1864 (Cycle 26 — Cluster Expansion)
