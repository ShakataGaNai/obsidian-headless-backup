# obsidian-vault-backup

Containerized tool that syncs an [Obsidian](https://obsidian.md) vault via the official [`obsidian-headless`](https://github.com/obsidianmd/obsidian-headless) CLI and backs it up to git. Designed for Kubernetes CronJobs or Docker Compose.

## How It Works

1. **Sync** — pulls your vault from Obsidian's servers using `obsidian-headless`
2. **Backup** — commits and pushes changes to a git remote

On first run, the container sets up sync configuration (vault link, sync mode, etc.). Subsequent runs perform incremental syncs and only commit when files have changed.

## Prerequisites

- An [Obsidian Sync](https://obsidian.md/sync) subscription
- A remote vault already created (via the Obsidian desktop/mobile app)
- Node.js 22+ installed locally (for initial token generation)
- A git repo for backup storage (GitHub, Gitea, Forgejo, etc.)
- A deploy key (ed25519) with write access to that repo

## Getting Your Auth Token

```bash
npm install -g obsidian-headless
ob login
# Token is stored at ~/.obsidian-headless/auth_token
cat ~/.obsidian-headless/auth_token
```

Store this token securely — it grants full access to all vaults on the account.

## Quick Start — Docker Compose

```bash
# 1. Copy and edit .env
cp .env.example .env
# Fill in OBSIDIAN_AUTH_TOKEN, VAULT_NAME, GIT_REMOTE_URL

# 2. Place your deploy key
mkdir -p git-ssh
cp /path/to/deploy-key ./git-ssh/id_ed25519
chmod 600 ./git-ssh/id_ed25519

# 3. Build and run once (test)
docker compose run --rm obsidian-vault-backup

# 4. For scheduled runs, use host cron:
# crontab -e
# 0 4 * * * cd /path/to/obsidian-vault-backup && docker compose run --rm obsidian-vault-backup >> /var/log/obsidian-backup.log 2>&1
```

Works with Podman too — just use `podman compose` or `podman-compose`.

## Quick Start — Kubernetes

```bash
# 1. Get your auth token (see above)

# 2. Generate a deploy key
ssh-keygen -t ed25519 -f ./deploy-key -N ""
# Add deploy-key.pub to your git repo as a deploy key with write access

# 3. Create the secret
kubectl create namespace obsidian-backup
kubectl -n obsidian-backup create secret generic obsidian-backup-secrets \
  --from-literal=OBSIDIAN_AUTH_TOKEN="your-token" \
  --from-literal=E2EE_PASSWORD="your-e2ee-password" \
  --from-file=git-ssh-key=./deploy-key

# 4. Edit kubernetes/base/cronjob.yaml with your values (image, vault name, git URL)

# 5. Apply the manifests
kubectl apply -k kubernetes/overlays/k8s-secrets/

# 6. Trigger a test run
kubectl -n obsidian-backup create job --from=cronjob/obsidian-vault-backup test-run

# 7. Watch logs
kubectl -n obsidian-backup logs -f job/test-run
```

### 1Password (Kubernetes)

If you use the [1Password Kubernetes Operator](https://github.com/1Password/onepassword-operator):

1. Create a 1Password item at `vaults/HomeLab/items/obsidian-vault-backup` with fields:
   - `OBSIDIAN_AUTH_TOKEN` — your auth token
   - `E2EE_PASSWORD` — your E2EE password (omit for standard encryption)
   - `git-ssh-key` — your SSH private deploy key
2. Edit the `itemPath` in `kubernetes/overlays/1password/onepassworditem.yaml` if needed
3. Apply: `kubectl apply -k kubernetes/overlays/1password/`

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
| `TZ` | no | `UTC` | Timezone for commit timestamps |

## Sync Modes

- **`mirror-remote`** (default) — one-way pull from Obsidian servers. Safest for backups — the container never pushes changes back. If local files get corrupted, they're overwritten from the server.
- **`pull-only`** — pulls changes but won't overwrite local modifications.
- **`bidirectional`** — full two-way sync. Only use this if you know what you're doing.

## What Gets Backed Up

The git backup includes your vault files and `.obsidian/` configs (plugins, themes, snippets, etc.). It excludes:

- Sync state databases (`*.db`, `sync.json`, `sync-journal/`)
- The vault-backup marker file
- OS junk files (`.DS_Store`, `Thumbs.db`)

## Changing the Schedule

**Kubernetes:** Edit the `schedule` field in `kubernetes/base/cronjob.yaml`:

- `"0 4 * * *"` — daily at 4:00 AM
- `"0 */6 * * *"` — every 6 hours
- `"*/30 * * * *"` — every 30 minutes

**Docker Compose:** Edit your host crontab entry.

## Multi-Vault Support

Deploy separate instances (CronJob + PVC per vault). Each needs its own `VAULT_NAME`, `E2EE_PASSWORD` (if different), and optionally different git repos or branches.

## Persistent Storage

A single PVC mounted at `/vault` stores both vault files and Obsidian sync state (in `.obsidian/`). This must persist between runs to avoid full re-syncs.

**Sizing:** Text-only vaults need ~1Gi. Vaults with attachments (images, PDFs) may need 5-10Gi+. E2EE vaults sync the entire vault every time — plan accordingly.

**Storage backend:** Avoid NFS-backed PVCs — SQLite (used by obsidian-headless for sync state) has locking issues on NFS. Use local-path or block storage.

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
