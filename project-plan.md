# obsidian-vault-backup — Project Plan

A containerized tool that syncs an Obsidian vault via the official headless CLI and backs it up to git (with future support for s3, rsync, etc). Designed to run as a Kubernetes CronJob or via Docker Compose.

## Background & Key References

- **obsidian-headless**: <https://github.com/obsidianmd/obsidian-headless> (npm: `obsidian-headless`, v0.0.5 as of 2025-03-06)
- Requires **Node.js 22+**
- Pure CLI — no Electron/GUI dependencies
- Supports E2EE and standard encryption vaults
- Auth via `OBSIDIAN_AUTH_TOKEN` env var for non-interactive use
- Sync modes: `bidirectional`, `pull-only`, `mirror-remote` (set via `ob sync-config --mode`)
- Uses an internal SQLite DB to track sync state — **must be persisted** between runs for incremental sync
- On Linux, the `btime` (file creation time) addon is not available; sync works fine, only birth timestamps are lost
- **Important caveat**: E2EE vaults cannot do partial/selective sync — the entire vault syncs every time. Plan storage accordingly.
- The tool is very new (days old). Pin versions in Dockerfile and expect breaking changes.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  K8s CronJob / Docker Compose scheduled service │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │          obsidian-vault-backup             │  │
│  │                                           │  │
│  │  1. ob sync --path /vault                 │  │
│  │     (pull-only or mirror-remote mode)     │  │
│  │                                           │  │
│  │  2. backup-provider (git | s3 | rsync)    │  │
│  │     git add -A && git commit && git push  │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  Volumes:                                       │
│    /vault          — vault files (PVC)          │
│    /vault-state    — ob sync SQLite DB (PVC)    │
│    /git-ssh        — SSH key (Secret mount)     │
└─────────────────────────────────────────────────┘
```

### Persistent Storage Requirements

Two things **must** persist between runs to avoid full re-sync every time:

1. **Vault files** (`/vault`) — the actual markdown/attachment files
2. **Obsidian sync state** — the `.obsidian` directory inside the vault contains sync metadata (including an SQLite database). This lives at `/vault/.obsidian/` by default (configurable via `--config-dir`).

A single PVC mounted at `/vault` covers both. The vault is also the git working tree.

---

## Project Structure

```
obsidian-vault-backup/
├── Dockerfile
├── scripts/
│   └── entrypoint.sh          # main orchestration script
├── kubernetes/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── pvc.yaml
│   │   ├── cronjob.yaml
│   │   └── secret.yaml         # template / sealed-secret placeholder
│   └── overlays/
│       ├── k8s-secrets/
│       │   ├── kustomization.yaml
│       │   └── secret.yaml
│       └── 1password/
│           ├── kustomization.yaml
│           └── onepassworditem.yaml
├── docker-compose.yaml
├── .env.example
├── README.md
└── LICENSE                      # MIT
```

---

## Component Specs

### 1. Dockerfile

```dockerfile
FROM node:22-alpine

# Pin the version — this tool is brand new, expect breaking changes
ARG OB_HEADLESS_VERSION=0.0.5

RUN npm install -g obsidian-headless@${OB_HEADLESS_VERSION} \
    && apk add --no-cache \
        git \
        openssh-client \
        bash \
        tzdata

# Create non-root user
RUN addgroup -g 1000 obsidian && adduser -u 1000 -G obsidian -D obsidian

# Vault and state will be mounted here
RUN mkdir -p /vault && chown obsidian:obsidian /vault

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER obsidian
WORKDIR /vault

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**Build notes:**
- Pin `obsidian-headless` version via build arg so we can bump deliberately
- `node:22-alpine` keeps the image small (~180MB expected)
- Non-root user (UID 1000) — important for PVC permission compatibility with k3s default storage classes
- `tzdata` so git commit timestamps use the correct timezone

### 2. Entrypoint Script (`scripts/entrypoint.sh`)

This is the core orchestration logic. It should:

1. **First-run detection**: Check if `/vault/.obsidian/sync.json` (or equivalent sync state file) exists. If not, run initial setup.
2. **Sync setup** (first run only): `ob sync-setup --vault "$VAULT_NAME" --path /vault --password "$E2EE_PASSWORD" --device-name "$DEVICE_NAME" --config-dir "$CONFIG_DIR"`
3. **Configure sync mode** (first run only): `ob sync-config --path /vault --mode "$SYNC_MODE"` — default to `mirror-remote` for pure backup use case
4. **Optionally configure what to sync** (first run only): file types, config categories, excluded folders via `ob sync-config`
5. **Run sync**: `ob sync --path /vault`
6. **Run backup provider**: dispatch to the configured backup method (git, or future s3/rsync)
7. **Exit cleanly**: CronJob expects exit 0 on success

#### Environment Variables

The entrypoint should be entirely configured via env vars:

| Variable | Required | Default | Description |
|---|---|---|---|
| `OBSIDIAN_AUTH_TOKEN` | **yes** | — | Auth token from `ob login` |
| `VAULT_NAME` | **yes** | — | Remote vault name or ID |
| `E2EE_PASSWORD` | no | — | E2EE encryption password. Omit for standard encryption vaults. |
| `DEVICE_NAME` | no | `vault-backup` | Device name shown in Obsidian sync version history |
| `CONFIG_DIR` | no | `.obsidian` | Obsidian config directory name |
| `SYNC_MODE` | no | `mirror-remote` | `bidirectional`, `pull-only`, or `mirror-remote` |
| `SYNC_FILE_TYPES` | no | `image,audio,video,pdf,unsupported` | Comma-separated attachment types to sync |
| `SYNC_CONFIGS` | no | _(empty = don't sync configs)_ | Comma-separated config categories to sync |
| `SYNC_EXCLUDED_FOLDERS` | no | _(empty)_ | Comma-separated folders to exclude |
| `CONFLICT_STRATEGY` | no | `merge` | `merge` or `conflict` |
| `BACKUP_PROVIDER` | no | `git` | `git` (future: `s3`, `rsync`, `none`) |
| `GIT_REMOTE_URL` | no* | — | Git remote URL (SSH). Required if `BACKUP_PROVIDER=git` |
| `GIT_BRANCH` | no | `main` | Branch to push to |
| `GIT_COMMIT_MESSAGE` | no | `vault backup %DATE%` | Commit message template. `%DATE%` replaced with ISO timestamp |
| `GIT_AUTHOR_NAME` | no | `Obsidian Vault Backup` | Git author name |
| `GIT_AUTHOR_EMAIL` | no | `vault-backup@noreply` | Git author email |
| `GIT_SSH_KEY_PATH` | no | `/git-ssh/id_ed25519` | Path to SSH private key for git push |
| `TZ` | no | `UTC` | Timezone for commit timestamps |

#### Entrypoint Logic (pseudocode)

```bash
#!/usr/bin/env bash
set -euo pipefail

VAULT_PATH="/vault"
FIRST_RUN_MARKER="$VAULT_PATH/.obsidian/.vault-backup-initialized"

# ── First-run setup ───────────────────────────────
if [[ ! -f "$FIRST_RUN_MARKER" ]]; then
    echo "[init] First run detected. Setting up sync..."

    # Link local vault to remote
    ob sync-setup \
        --vault "${VAULT_NAME}" \
        --path "$VAULT_PATH" \
        ${E2EE_PASSWORD:+--password "$E2EE_PASSWORD"} \
        --device-name "${DEVICE_NAME:-vault-backup}" \
        --config-dir "${CONFIG_DIR:-.obsidian}"

    # Configure sync mode (default mirror-remote for backup safety)
    SYNC_CONFIG_ARGS="--path $VAULT_PATH --mode ${SYNC_MODE:-mirror-remote}"
    [[ -n "${CONFLICT_STRATEGY:-}" ]]    && SYNC_CONFIG_ARGS+=" --conflict-strategy $CONFLICT_STRATEGY"
    [[ -n "${SYNC_FILE_TYPES:-}" ]]      && SYNC_CONFIG_ARGS+=" --file-types $SYNC_FILE_TYPES"
    [[ -n "${SYNC_CONFIGS:-}" ]]         && SYNC_CONFIG_ARGS+=" --configs $SYNC_CONFIGS"
    [[ -n "${SYNC_EXCLUDED_FOLDERS:-}" ]] && SYNC_CONFIG_ARGS+=" --excluded-folders $SYNC_EXCLUDED_FOLDERS"
    ob sync-config $SYNC_CONFIG_ARGS

    touch "$FIRST_RUN_MARKER"
    echo "[init] Setup complete."
fi

# ── Sync ──────────────────────────────────────────
echo "[sync] Starting Obsidian Sync..."
ob sync --path "$VAULT_PATH"
echo "[sync] Sync complete."

# ── Backup ────────────────────────────────────────
BACKUP_PROVIDER="${BACKUP_PROVIDER:-git}"

case "$BACKUP_PROVIDER" in
    git)
        source /usr/local/bin/backup-git.sh
        ;;
    s3)
        echo "[backup] s3 provider not yet implemented"
        exit 1
        ;;
    rsync)
        echo "[backup] rsync provider not yet implemented"
        exit 1
        ;;
    none)
        echo "[backup] No backup provider configured. Skipping."
        ;;
    *)
        echo "[error] Unknown BACKUP_PROVIDER: $BACKUP_PROVIDER"
        exit 1
        ;;
esac

echo "[done] Vault backup complete."
```

#### Git Backup Provider (`scripts/backup-git.sh`)

```bash
#!/usr/bin/env bash
# Sourced by entrypoint.sh — inherits all env vars
set -euo pipefail

VAULT_PATH="/vault"
GIT_SSH_KEY="${GIT_SSH_KEY_PATH:-/git-ssh/id_ed25519}"

# Configure SSH for git
export GIT_SSH_COMMAND="ssh -i $GIT_SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"

cd "$VAULT_PATH"

# Initialize git repo if not already
if [[ ! -d ".git" ]]; then
    echo "[git] Initializing git repo..."
    git init -b "${GIT_BRANCH:-main}"
    git remote add origin "${GIT_REMOTE_URL}"

    # Create .gitignore for obsidian internal state
    # We DO want to back up .obsidian/ configs (plugins, themes, etc)
    # but NOT the sync state database
    cat > .gitignore <<'EOF'
# Obsidian sync internal state — do not commit
.obsidian/sync.json
.obsidian/sync-journal/
.obsidian/*.db
.obsidian/*.db-wal
.obsidian/*.db-shm

# Vault backup marker
.obsidian/.vault-backup-initialized

# OS junk
.DS_Store
Thumbs.db
EOF
fi

# Configure git identity
git config user.name "${GIT_AUTHOR_NAME:-Obsidian Vault Backup}"
git config user.email "${GIT_AUTHOR_EMAIL:-vault-backup@noreply}"

# Stage everything
git add -A

# Commit only if there are changes
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MSG="${GIT_COMMIT_MESSAGE:-vault backup %DATE%}"
MSG="${MSG//%DATE%/$DATE}"

if git diff --cached --quiet; then
    echo "[git] No changes to commit."
else
    git commit -m "$MSG"
    echo "[git] Committed changes."
fi

# Push
echo "[git] Pushing to ${GIT_BRANCH:-main}..."
git push -u origin "${GIT_BRANCH:-main}"
echo "[git] Push complete."
```

**Design decisions for git backup:**
- `.gitignore` excludes sync state DB files but includes `.obsidian/` configs (plugins, themes, snippets — these are useful to back up)
- `StrictHostKeyChecking=accept-new` — accepts new host keys on first connect, rejects changed keys. Reasonable balance for automated use.
- Only commits when there are actual changes (no empty commits cluttering history)
- Uses `%DATE%` template in commit message for easy customization

### 3. Kubernetes Manifests

#### base/namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: obsidian-backup
```

#### base/pvc.yaml

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: obsidian-vault
  namespace: obsidian-backup
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi  # Adjust based on vault size
  # storageClassName: local-path  # k3s default — uncomment or set to your SC
```

**Sizing note:** E2EE vaults sync the entire vault every time. A vault with lots of attachments (images, PDFs) can be multiple GB. Size the PVC accordingly. For text-only vaults, 1Gi is plenty.

#### base/cronjob.yaml

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: obsidian-vault-backup
  namespace: obsidian-backup
spec:
  schedule: "0 4 * * *"  # Daily at 4am — configurable
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 1800  # 30min timeout
      template:
        spec:
          restartPolicy: OnFailure
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
          containers:
            - name: vault-backup
              image: ghcr.io/YOURORG/obsidian-vault-backup:latest  # replace
              imagePullPolicy: IfNotPresent
              envFrom:
                - secretRef:
                    name: obsidian-backup-secrets
              env:
                - name: VAULT_NAME
                  value: "My Vault"
                - name: SYNC_MODE
                  value: "mirror-remote"
                - name: BACKUP_PROVIDER
                  value: "git"
                - name: GIT_REMOTE_URL
                  value: "git@github.com:YOURORG/obsidian-vault-backup-data.git"
                - name: GIT_BRANCH
                  value: "main"
                - name: TZ
                  value: "America/Los_Angeles"
              volumeMounts:
                - name: vault-data
                  mountPath: /vault
                - name: git-ssh
                  mountPath: /git-ssh
                  readOnly: true
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
          volumes:
            - name: vault-data
              persistentVolumeClaim:
                claimName: obsidian-vault
            - name: git-ssh
              secret:
                secretName: obsidian-backup-secrets
                items:
                  - key: git-ssh-key
                    path: id_ed25519
                    mode: 0400
```

**Notes:**
- `concurrencyPolicy: Forbid` prevents overlapping runs
- `activeDeadlineSeconds: 1800` — 30 min timeout. First run (full sync of large E2EE vault) may need more; adjust as needed.
- `fsGroup: 1000` ensures the PVC is writable by the non-root container user
- Schedule uses standard cron syntax. `"0 4 * * *"` = daily at 4am. `"0 */6 * * *"` = every 6 hours. etc.

#### overlays/k8s-secrets/secret.yaml

Standard Kubernetes Secret. Values are base64 encoded at apply time.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: obsidian-backup-secrets
  namespace: obsidian-backup
type: Opaque
stringData:
  OBSIDIAN_AUTH_TOKEN: "your-auth-token-here"
  E2EE_PASSWORD: "your-e2ee-password-here"     # omit if using standard encryption
  git-ssh-key: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...your deploy key...
    -----END OPENSSH PRIVATE KEY-----
```

**Security notes:**
- This file should **never** be committed to git. Add to `.gitignore`.
- For production use, consider Sealed Secrets, SOPS, or external secret providers.
- The git SSH key should be a dedicated **deploy key** with write access, not a personal SSH key.

#### overlays/1password/onepassworditem.yaml

For users running the [1Password Connect Kubernetes Operator](https://github.com/1Password/onepassword-operator):

```yaml
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: obsidian-backup-secrets
  namespace: obsidian-backup
spec:
  itemPath: "vaults/HomeLab/items/obsidian-vault-backup"
```

**1Password item setup instructions:**

Create an item in your 1Password vault with these fields:

| Field Name (label) | Type | Value |
|---|---|---|
| `OBSIDIAN_AUTH_TOKEN` | password | Your auth token from `ob login` |
| `E2EE_PASSWORD` | password | Your vault's E2EE password (omit for standard encryption) |
| `git-ssh-key` | password / note | Contents of your SSH private deploy key |

The 1Password operator will create a Kubernetes Secret with the same name (`obsidian-backup-secrets`) and the field labels as keys — matching exactly what the CronJob expects.

**1Password operator prerequisites:**
- 1Password Connect server deployed (or 1Password Service Account configured)
- `onepassword-operator` deployed to the cluster
- The operator's service account has access to the specified vault

#### overlays/1password/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: obsidian-backup
resources:
  - ../../base
  - onepassworditem.yaml
# The base secret.yaml is replaced by the OnePasswordItem
patchesStrategicMerge: []
```

### 4. Docker Compose (non-Kubernetes usage)

```yaml
services:
  obsidian-vault-backup:
    build: .
    # Or use a prebuilt image:
    # image: ghcr.io/YOURORG/obsidian-vault-backup:latest
    env_file:
      - .env
    volumes:
      - vault-data:/vault
      - ./git-ssh/id_ed25519:/git-ssh/id_ed25519:ro
    # No built-in cron in the container — use host cron, systemd timer, or:
    # Option A: Run once and exit (trigger from host cron / systemd timer)
    # Option B: Use a sidecar or wrapper that handles scheduling

    # For scheduled runs without host cron, wrap with supercronic:
    # (see alternative Dockerfile below)

# Named volume persists vault + sync state between runs
volumes:
  vault-data:
```

#### .env.example

```bash
# Required
OBSIDIAN_AUTH_TOKEN=your-auth-token-here
VAULT_NAME=My Vault

# E2EE (omit for standard encryption vaults)
E2EE_PASSWORD=your-e2ee-password-here

# Sync settings
SYNC_MODE=mirror-remote
# SYNC_FILE_TYPES=image,audio,video,pdf,unsupported
# SYNC_CONFIGS=
# SYNC_EXCLUDED_FOLDERS=
# CONFLICT_STRATEGY=merge
# DEVICE_NAME=vault-backup
# CONFIG_DIR=.obsidian

# Backup provider
BACKUP_PROVIDER=git
GIT_REMOTE_URL=git@github.com:YOURORG/obsidian-vault-backup-data.git
GIT_BRANCH=main
# GIT_COMMIT_MESSAGE=vault backup %DATE%
# GIT_AUTHOR_NAME=Obsidian Vault Backup
# GIT_AUTHOR_EMAIL=vault-backup@noreply

# Timezone
TZ=America/Los_Angeles
```

#### Docker Compose with built-in scheduling (alternative)

For users who don't want to rely on host cron, add `supercronic` to the Dockerfile:

```dockerfile
# Add to Dockerfile
ARG SUPERCRONIC_VERSION=0.2.33
ARG SUPERCRONIC_SHA256=...
RUN wget -O /usr/local/bin/supercronic \
    "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    && chmod +x /usr/local/bin/supercronic

COPY crontab /etc/supercronic/crontab
```

```
# crontab
0 4 * * * /usr/local/bin/entrypoint.sh >> /proc/1/fd/1 2>&1
```

Then in compose, override the entrypoint:

```yaml
services:
  obsidian-vault-backup:
    # ...
    entrypoint: ["/usr/local/bin/supercronic", "/etc/supercronic/crontab"]
    environment:
      - CRON_SCHEDULE=0 4 * * *  # document only — actual schedule in crontab
```

Alternatively, add an `ENABLE_CRON` env var that switches entrypoint behavior between one-shot and scheduled mode. This is cleaner:

```bash
# In entrypoint.sh, at the very top:
if [[ "${ENABLE_CRON:-false}" == "true" ]]; then
    echo "${CRON_SCHEDULE:-0 4 * * *} /usr/local/bin/entrypoint.sh" > /tmp/crontab
    exec supercronic /tmp/crontab
fi
# ... rest of one-shot logic
```

---

## Obtaining the Auth Token

The `OBSIDIAN_AUTH_TOKEN` is required for non-interactive operation. To obtain it:

1. Install `obsidian-headless` locally: `npm install -g obsidian-headless`
2. Run `ob login` — enter your Obsidian account email, password, and MFA if enabled
3. The token is stored in `~/.config/obsidian-headless/` (or platform equivalent)
4. Extract the token value and store it in your secret backend

**Note:** Document the exact file path and key name for the token once confirmed — the tool is new and this may change. The README should instruct users to check `ob login` output.

---

## Security Considerations

1. **Auth token scope**: The `OBSIDIAN_AUTH_TOKEN` grants full access to all vaults on the account. There is no per-vault scoping. Treat it as a highly sensitive credential.
2. **E2EE password**: If using E2EE, the encryption password is passed as an env var. In Kubernetes, this lives in a Secret object (encrypted at rest if etcd encryption is enabled). With 1Password operator, it never touches disk unencrypted.
3. **Git SSH key**: Use a dedicated deploy key (ed25519) scoped to a single repo with write access. Do not reuse personal SSH keys.
4. **Container runs as non-root** (UID 1000). No privileged capabilities needed.
5. **Network policy**: The container only needs outbound HTTPS to `sync-*.obsidian.md` (ports 443) and SSH to your git remote (port 22). Consider adding a NetworkPolicy in the Kubernetes manifests to restrict egress.
6. **Sync mode**: Default to `mirror-remote` for backup use cases. This ensures the backup container never pushes local changes back to your vault. If the git repo gets corrupted or files are accidentally deleted in the PVC, `mirror-remote` will re-download from the server and overwrite local state.
7. **PVC encryption**: If your k3s storage class supports encryption at rest, enable it. The vault files are decrypted on disk after sync (even for E2EE vaults — E2EE only protects in-transit and at-rest on Obsidian's servers).

---

## Usage Instructions (for README.md)

### Prerequisites

- An [Obsidian Sync](https://obsidian.md/sync) subscription
- A remote vault already created (via the Obsidian desktop/mobile app)
- Node.js 22+ installed locally (for initial token generation)
- A git repo for backup storage (GitHub, Gitea, Forgejo, etc.)
- A deploy key (ed25519) with write access to that repo

### Quick Start — Kubernetes

```bash
# 1. Get your auth token
npm install -g obsidian-headless
ob login
# Note the token from ~/.config/obsidian-headless/ (or check ob login output)

# 2. Generate a deploy key
ssh-keygen -t ed25519 -f ./deploy-key -N ""
# Add deploy-key.pub to your git repo as a deploy key with write access

# 3. Create the secret
kubectl create namespace obsidian-backup
kubectl -n obsidian-backup create secret generic obsidian-backup-secrets \
  --from-literal=OBSIDIAN_AUTH_TOKEN="your-token" \
  --from-literal=E2EE_PASSWORD="your-e2ee-password" \
  --from-file=git-ssh-key=./deploy-key

# 4. Apply the manifests
kubectl apply -k kubernetes/overlays/k8s-secrets/

# 5. Trigger a test run
kubectl -n obsidian-backup create job --from=cronjob/obsidian-vault-backup test-run

# 6. Watch logs
kubectl -n obsidian-backup logs -f job/test-run
```

### Quick Start — Docker Compose

```bash
# 1. Get your auth token (same as above)

# 2. Copy and edit .env
cp .env.example .env
# Fill in your values

# 3. Place your deploy key
mkdir -p git-ssh
cp /path/to/deploy-key ./git-ssh/id_ed25519
chmod 600 ./git-ssh/id_ed25519

# 4. Run once (test)
docker compose run --rm obsidian-vault-backup

# 5. For scheduled runs, use host cron:
# crontab -e
# 0 4 * * * cd /path/to/obsidian-vault-backup && docker compose run --rm obsidian-vault-backup >> /var/log/obsidian-backup.log 2>&1
```

### Quick Start — 1Password (Kubernetes)

```bash
# 1. Create the 1Password item (see field mapping above)

# 2. Ensure 1Password Connect + operator are deployed to your cluster

# 3. Apply manifests
kubectl apply -k kubernetes/overlays/1password/

# 4. Verify the secret was created
kubectl -n obsidian-backup get secret obsidian-backup-secrets

# 5. Trigger a test run
kubectl -n obsidian-backup create job --from=cronjob/obsidian-vault-backup test-run
```

### Changing the Schedule

**Kubernetes:** Edit the `schedule` field in `cronjob.yaml`. Standard cron syntax. Examples:
- `"0 4 * * *"` — daily at 4:00 AM
- `"0 */6 * * *"` — every 6 hours
- `"0 */1 * * *"` — every hour
- `"*/30 * * * *"` — every 30 minutes

**Docker Compose:** Edit your host crontab or the `CRON_SCHEDULE` env var if using the supercronic variant.

### Multi-Vault Support

To back up multiple vaults, deploy separate instances (CronJob + PVC per vault). Each needs its own:
- PVC (different vault data)
- `VAULT_NAME` value
- `E2EE_PASSWORD` (if different per vault)
- Optionally different git repos or branches

---

## Future Backup Providers

The backup provider interface is a simple shell script sourced by the entrypoint. To add a new provider:

1. Create `scripts/backup-<provider>.sh`
2. The script receives all env vars and has access to `/vault`
3. Add the case to the `BACKUP_PROVIDER` dispatch in `entrypoint.sh`
4. Add any new env vars to the documentation table
5. Add any new binaries to the Dockerfile (e.g., `aws-cli` for s3, `rsync` for rsync)

### Planned Providers

**s3** — `aws s3 sync /vault s3://bucket/prefix --delete`
- Env vars: `S3_BUCKET`, `S3_PREFIX`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `S3_ENDPOINT` (for MinIO/SeaweedFS)

**rsync** — `rsync -avz --delete /vault/ user@host:/path/`
- Env vars: `RSYNC_DEST`, `RSYNC_SSH_KEY_PATH`, `RSYNC_EXTRA_ARGS`

---

## Implementation Notes for Claude Code

### Order of Operations

1. **Dockerfile** — get a working container image first. Test locally with `docker build` + `docker run`.
2. **entrypoint.sh + backup-git.sh** — the core scripts. Test the full flow locally with Docker before touching Kubernetes.
3. **.env.example** — document all env vars.
4. **Kubernetes base manifests** — namespace, PVC, CronJob, Secret template.
5. **Kustomize overlays** — k8s-secrets and 1password variants.
6. **docker-compose.yaml** — for non-k8s users.
7. **README.md** — comprehensive usage docs (use the "Usage Instructions" section above as a starting point, expand with troubleshooting).
8. **LICENSE** — MIT.

### Testing Checklist

- [ ] Docker image builds successfully
- [ ] Container runs as non-root (UID 1000)
- [ ] First-run: `ob sync-setup` executes and creates sync state
- [ ] First-run: `ob sync-config` applies configured mode
- [ ] First-run: git repo initializes with correct remote and .gitignore
- [ ] Subsequent runs: skips setup, runs incremental sync
- [ ] Subsequent runs: only commits when files actually changed
- [ ] E2EE vault: password passed correctly, decryption works
- [ ] Standard encryption vault: works without E2EE_PASSWORD set
- [ ] Git push succeeds with deploy key
- [ ] CronJob triggers on schedule in k3s
- [ ] PVC persists data between CronJob runs
- [ ] 1Password overlay: secret created correctly by operator
- [ ] `BACKUP_PROVIDER=none` skips backup step cleanly
- [ ] Container exits 0 on success, non-zero on failure
- [ ] Logs are clean and informative (timestamps, step labels)

### Known Issues / Caveats to Document

1. **First run may be slow**: Full vault sync (especially E2EE) downloads everything. Could take 10+ minutes for large vaults. Set `activeDeadlineSeconds` accordingly.
2. **obsidian-headless is v0.0.x**: Expect breaking changes. Pin the version and test upgrades deliberately.
3. **Auth token refresh**: Unknown if the token expires. Document how to rotate it.
4. **File creation timestamps**: The `btime` addon doesn't work on Linux. Git doesn't preserve timestamps anyway, so this is a non-issue for the git backup provider. But worth noting for future providers (s3 sync preserves mtime).
5. **Vault filename leakage in git history**: Even with E2EE, filenames are visible in git. If filename privacy matters, the git repo should be private.
6. **Concurrent sync risk**: `concurrencyPolicy: Forbid` on the CronJob prevents this, but Docker Compose users need to be careful not to run overlapping instances.
7. **SQLite on NFS**: If the PVC uses NFS-backed storage, SQLite may have locking issues. Recommend local-path or block storage.
