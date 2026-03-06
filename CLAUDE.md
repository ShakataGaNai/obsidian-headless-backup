# obsidian-vault-backup

Containerized tool that syncs an Obsidian vault via `obsidian-headless` CLI and backs it up to git. Runs as a one-shot container for Kubernetes CronJobs or Docker Compose with host cron.

## Project Structure

```
Dockerfile                              # node:22-alpine, obsidian-headless@0.0.6, non-root (node, UID 1000)
scripts/entrypoint.sh                   # Main orchestration: env validation, first-run setup, sync, backup dispatch
scripts/backup-git.sh                   # Git backup provider: init, commit-on-change, push
docker-compose.yaml                     # Single service with named volume
.env.example                            # All env vars documented
kubernetes/base/                        # Namespace, PVC, CronJob, kustomization
kubernetes/overlays/k8s-secrets/        # Standard K8s Secret + kustomization
kubernetes/overlays/1password/          # OnePasswordItem + kustomization
```

## Key Design Decisions

- **One-shot mode only** — no internal cron/scheduler. K8s CronJob or host cron handles scheduling.
- **Uses `node` user (UID 1000)** from `node:22-alpine` base image — don't create a custom user.
- **`obsidian-headless` pinned to 0.0.6** via Dockerfile build arg. Tool is very new; pin deliberately.
- **First-run detection** uses marker file at `/vault/.obsidian/.vault-backup-initialized`.
- **Git backup** only commits when files actually changed. `.gitignore` in the vault excludes sync state DBs but includes `.obsidian/` configs.
- **Backup provider pattern** — `scripts/backup-<provider>.sh` sourced by entrypoint. Currently only `git`; `s3` and `rsync` are stubbed.

## Working With Shell Scripts

- Scripts use `bash` (not `sh`) with `set -euo pipefail`.
- `log()` function in entrypoint.sh provides timestamped output.
- `backup-git.sh` is sourced (not executed) by `entrypoint.sh` — it inherits all env vars and the `log` function.
- Use arrays for building command args (not string concatenation).

## Building and Testing

```bash
# Build
podman build -t obsidian-vault-backup .

# Dry run (no credentials) — should exit 1 with clear error
podman run --rm obsidian-vault-backup

# Verify non-root
podman run --rm --entrypoint id obsidian-vault-backup

# Validate K8s manifests
kubectl kustomize kubernetes/overlays/k8s-secrets/
kubectl kustomize kubernetes/overlays/1password/
```

## Environment Variables

Required: `OBSIDIAN_AUTH_TOKEN`, `VAULT_NAME`. See `.env.example` for full list with defaults.

`GIT_REMOTE_URL` is required when `BACKUP_PROVIDER=git` (the default).

## Kubernetes

- Both overlays include base resources (namespace, PVC, CronJob) plus their secret mechanism.
- The CronJob's pod security context sets `runAsUser/runAsGroup/fsGroup: 1000`.
- SSH key is mounted from the secret at `/git-ssh/id_ed25519` with mode 0400.
