# obsidian-vault-backup

Containerized tool that syncs an [Obsidian](https://obsidian.md) vault via the official [`obsidian-headless`](https://github.com/obsidianmd/obsidian-headless) CLI and backs it up to git. Designed for Kubernetes CronJobs or Docker Compose.

## How It Works

1. **Sync** — pulls your vault from Obsidian's servers using `obsidian-headless`
2. **Backup** — commits and pushes changes to a git remote

On first run, the container sets up sync configuration (vault link, sync mode, etc.). Subsequent runs perform incremental syncs and only commit when files have changed.

## Prerequisites

1. An [Obsidian Sync](https://obsidian.md/sync) subscription with a remote vault already created
2. An **Obsidian auth token** — install `obsidian-headless` locally (`npm install -g obsidian-headless`), run `ob login`, then grab the token from `~/.obsidian-headless/auth_token`. This token grants full access to all vaults on the account — store it securely.
3. A **git repo** for backup storage with an **SSH deploy key** that has write access

## Docker Compose

```bash
# 1. Configure
cp .env.example .env
# Edit .env — set OBSIDIAN_AUTH_TOKEN, VAULT_NAME, GIT_REMOTE_URL

# 2. Place your deploy key
mkdir -p git-ssh
cp /path/to/deploy-key ./git-ssh/id_ed25519
chmod 600 ./git-ssh/id_ed25519

# 3. Run once (test)
docker compose run --rm obsidian-vault-backup

# 4. Schedule with host cron
# crontab -e
# 0 4 * * * cd /path/to/obsidian-vault-backup && docker compose run --rm obsidian-vault-backup >> /var/log/obsidian-backup.log 2>&1
```

Works with Podman too — `podman compose` or `podman-compose`.

## Kubernetes

### 1. Edit the ConfigMap

Open `kubernetes/obsidian-vault-backup.yaml` and edit the ConfigMap with your vault name, git remote URL, schedule, and other settings.

### 2. Create the Secret

Choose **one** of three options:

**Option A — `kubectl create secret` (quickest):**

```bash
kubectl apply -f kubernetes/obsidian-vault-backup.yaml
kubectl -n obsidian-backup create secret generic obsidian-backup-secrets \
  --from-literal=OBSIDIAN_AUTH_TOKEN="your-token" \
  --from-literal=E2EE_PASSWORD="your-e2ee-password" \
  --from-file=id_ed25519=/path/to/deploy-key
```

**Option B — Secret manifest:**

Edit `kubernetes/secret.yaml` with your credentials, then:

```bash
kubectl apply -f kubernetes/obsidian-vault-backup.yaml
kubectl apply -f kubernetes/secret.yaml
```

**Option C — 1Password Operator:**

If you use the [1Password Kubernetes Operator](https://github.com/1Password/onepassword-operator), edit the `itemPath` in `kubernetes/onepassworditem.yaml` to match your 1Password item, then:

```bash
kubectl apply -f kubernetes/obsidian-vault-backup.yaml
kubectl apply -f kubernetes/onepassworditem.yaml
```

### 3. Test

```bash
kubectl -n obsidian-backup create job --from=cronjob/obsidian-vault-backup test-run
kubectl -n obsidian-backup logs -f job/test-run
```

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `OBSIDIAN_AUTH_TOKEN` | **yes** | — | Auth token from `ob login` |
| `VAULT_NAME` | **yes** | — | Remote vault name or ID |
| `E2EE_PASSWORD` | no | — | E2EE encryption password (omit for standard encryption vaults) |
| `DEVICE_NAME` | no | `vault-backup` | Device name shown in Obsidian sync version history |
| `CONFIG_DIR` | no | `.obsidian` | Obsidian config directory name |
| `SYNC_MODE` | no | `mirror-remote` | `bidirectional`, `pull-only`, or `mirror-remote` |
| `SYNC_FILE_TYPES` | no | `image,audio,video,pdf,unsupported` | Comma-separated attachment types to sync |
| `SYNC_CONFIGS` | no | _(empty)_ | Comma-separated config categories to sync |
| `SYNC_EXCLUDED_FOLDERS` | no | _(empty)_ | Comma-separated folders to exclude |
| `CONFLICT_STRATEGY` | no | `merge` | `merge` or `conflict` |
| `BACKUP_PROVIDER` | no | `git` | `git` or `none` (future: `s3`, `rsync`) |
| `GIT_REMOTE_URL` | no* | — | Git remote URL (SSH). *Required if `BACKUP_PROVIDER=git` |
| `GIT_BRANCH` | no | `main` | Branch to push to |
| `GIT_COMMIT_MESSAGE` | no | `vault backup %DATE%` | Commit message template (`%DATE%` = ISO timestamp) |
| `GIT_AUTHOR_NAME` | no | `Obsidian Vault Backup` | Git author name |
| `GIT_AUTHOR_EMAIL` | no | `vault-backup@noreply` | Git author email |
| `GIT_SSH_KEY_PATH` | no | `/git-ssh/id_ed25519` | Path to SSH private key for git push |
| `SYNC_TIMEOUT` | no | `600` | Sync timeout in seconds (10 min default) |
| `HEALTHCHECK_URL` | no | — | URL to ping on successful completion (Healthchecks.io, Uptime Kuma, etc.) |
| `TZ` | no | `UTC` | Timezone for commit timestamps |

## Sync Modes

- **`mirror-remote`** (default) — one-way pull from Obsidian servers. Safest for backups — the container never pushes changes back. If local files get corrupted, they're overwritten from the server.
- **`pull-only`** — pulls changes but won't overwrite local modifications.
- **`bidirectional`** — full two-way sync. Only use this if you know what you're doing.

## What Gets Backed Up

The git backup includes your vault files and `.obsidian/` configs (plugins, themes, snippets, etc.). It excludes sync state databases (`*.db`, `sync.json`, `sync-journal/`), the vault-backup marker file, and OS junk files.

## Changing the Schedule

**Kubernetes:** Edit the `schedule` field in `kubernetes/obsidian-vault-backup.yaml`. Standard cron syntax — `"0 4 * * *"` (daily 4am), `"0 */6 * * *"` (every 6h), `"*/30 * * * *"` (every 30min).

**Docker Compose:** Edit your host crontab entry.

## Persistent Storage

A single PVC mounted at `/vault` stores both vault files and Obsidian sync state (in `.obsidian/`). This must persist between runs to avoid full re-syncs.

**Sizing:** Text-only vaults need ~1Gi. Vaults with attachments (images, PDFs) may need 5-10Gi+. E2EE vaults sync the entire vault every time — plan accordingly.

**Storage backend:** Avoid NFS-backed PVCs — SQLite has locking issues on NFS. Use local-path or block storage.

## Multi-Vault Support

Deploy separate instances (CronJob + PVC per vault). Each needs its own `VAULT_NAME`, `E2EE_PASSWORD` (if different), and optionally different git repos or branches.

## Monitoring

The container exits non-zero on failure, which integrates with Kubernetes job monitoring (`kube_cronjob_status_last_successful_time` via Prometheus/kube-state-metrics).

For lightweight monitoring without a full Prometheus stack, set `HEALTHCHECK_URL` to a dead man's switch service (Healthchecks.io, Uptime Kuma, Betterstack, Cronitor). The container pings the URL after a successful backup — if the ping stops arriving, the service alerts you.

## Security Notes

- The auth token grants full access to **all vaults** on the account (no per-vault scoping)
- Use a dedicated **deploy key** for git, not a personal SSH key
- Container runs as non-root (UID 1000)
- Even with E2EE, filenames are visible in git history — keep the backup repo private
- Default sync mode (`mirror-remote`) prevents the container from ever pushing changes back to Obsidian

## Troubleshooting

**First run is slow:** Full vault sync (especially E2EE) downloads everything. Can take 10+ minutes for large vaults. Increase `activeDeadlineSeconds` in the CronJob if needed.

**Auth token issues:** Tokens may expire. Re-run `ob login` locally and update the secret.

**Permission denied on PVC:** Ensure `fsGroup: 1000` is set in the pod security context (already configured in the provided CronJob manifest).

**"keychain unavailable" errors:** Expected on headless Linux — `obsidian-headless` handles this via the `OBSIDIAN_AUTH_TOKEN` env var instead of system keychain.

## Adding Backup Providers

The backup provider interface is a shell script sourced by the entrypoint. To add a new provider:

1. Create `scripts/backup-<provider>.sh`
2. Add the case to the `BACKUP_PROVIDER` dispatch in `scripts/entrypoint.sh`
3. Add any new binaries to the Dockerfile
4. Document new env vars

## License

[MIT](LICENSE)
