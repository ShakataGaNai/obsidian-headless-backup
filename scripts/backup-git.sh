#!/usr/bin/env bash
# Sourced by entrypoint.sh — inherits all env vars and log function
set -euo pipefail

VAULT_PATH="/vault"
GIT_SSH_KEY="${GIT_SSH_KEY_PATH:-/git-ssh/id_ed25519}"

# Validate git remote URL
if [[ -z "${GIT_REMOTE_URL:-}" ]]; then
    log "[error] GIT_REMOTE_URL is not set. Required when BACKUP_PROVIDER=git."
    exit 1
fi

# PVC mounts are owned by root; git 2.35.2+ rejects this as "dubious ownership".
# Must run before cd into the vault — git checks CWD ownership before any command.
git config --global --add safe.directory "$VAULT_PATH"

# Configure SSH for git
# accept-new: trusts on first connect, rejects if the key changes later.
# Known hosts persist in /vault/.ssh/known_hosts across runs via the PVC.
KNOWN_HOSTS="/vault/.ssh/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
if [[ -f "$GIT_SSH_KEY" ]]; then
    export GIT_SSH_COMMAND="ssh -i \"$GIT_SSH_KEY\" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\"$KNOWN_HOSTS\""
fi

cd "$VAULT_PATH"

# ── Git repo init ────────────────────────────────
if [[ ! -d ".git" ]]; then
    log "[git] Initializing git repo..."
    git init -b "${GIT_BRANCH:-main}"
fi

# Ensure remote is configured and matches GIT_REMOTE_URL (handles first init,
# partial-init recovery, and config changes via ConfigMap update)
current_remote=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$current_remote" ]]; then
    git remote add origin "${GIT_REMOTE_URL}"
    log "[git] Added remote: ${GIT_REMOTE_URL}"
elif [[ "$current_remote" != "${GIT_REMOTE_URL}" ]]; then
    git remote set-url origin "${GIT_REMOTE_URL}"
    log "[git] Updated remote: ${current_remote} → ${GIT_REMOTE_URL}"
fi

# If local repo has no commits but remote does (fresh PVC, disaster recovery),
# fetch remote history so push is a fast-forward instead of rejected.
if ! git rev-parse HEAD &>/dev/null; then
    if git fetch origin "${GIT_BRANCH:-main}" 2>/dev/null; then
        git reset --hard "origin/${GIT_BRANCH:-main}"
        log "[git] Resumed from existing remote history."
    fi
fi

# Ensure .gitignore exists (covers fresh init, pre-existing repos, and manual deletion)
if [[ ! -f ".gitignore" ]]; then
    cat > .gitignore <<'GITIGNORE'
# Obsidian sync internal state — do not commit
.obsidian/sync.json
.obsidian/sync-journal/
.obsidian/*.db
.obsidian/*.db-wal
.obsidian/*.db-shm

# Vault backup marker
.obsidian/.vault-backup-initialized

# SSH known hosts (managed by backup-git.sh)
.ssh/

# OS junk
.DS_Store
Thumbs.db
GITIGNORE
    log "[git] Created .gitignore"
fi

# ── Configure, stage, commit, push ──────────────
git config user.name "${GIT_AUTHOR_NAME:-Obsidian Vault Backup}"
git config user.email "${GIT_AUTHOR_EMAIL:-vault-backup@noreply}"

git add -A

DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MSG="${GIT_COMMIT_MESSAGE:-vault backup %DATE%}"
MSG="${MSG//%DATE%/$DATE}"

if git diff --cached --quiet; then
    log "[git] No changes to commit."
else
    git commit -m "$MSG"
    log "[git] Committed changes."
    log "[git] Pushing to ${GIT_BRANCH:-main}..."
    git push -u origin "${GIT_BRANCH:-main}"
    log "[git] Push complete."
fi
