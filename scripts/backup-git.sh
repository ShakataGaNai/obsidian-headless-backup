#!/usr/bin/env bash
# Sourced by entrypoint.sh — inherits all env vars and log function
set -euo pipefail

VAULT_PATH="/vault"
GIT_SSH_KEY="${GIT_SSH_KEY_PATH:-/git-ssh/id_ed25519}"

# Configure SSH for git
# accept-new: trusts on first connect, rejects if the key changes later.
# Known hosts persist in /vault/.ssh/known_hosts across runs via the PVC.
KNOWN_HOSTS="/vault/.ssh/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
if [[ -f "$GIT_SSH_KEY" ]]; then
    export GIT_SSH_COMMAND="ssh -i \"$GIT_SSH_KEY\" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\"$KNOWN_HOSTS\""
fi

cd "$VAULT_PATH"

# PVC mounts are owned by root; git 2.35.2+ rejects this as "dubious ownership"
git config --global --add safe.directory "$VAULT_PATH"

# Validate git remote URL
if [[ -z "${GIT_REMOTE_URL:-}" ]]; then
    log "[error] GIT_REMOTE_URL is not set. Required when BACKUP_PROVIDER=git."
    exit 1
fi

# Initialize git repo if not already
if [[ ! -d ".git" ]]; then
    log "[git] Initializing git repo..."
    git init -b "${GIT_BRANCH:-main}"

    # Create .gitignore for obsidian internal state
    # We DO want to back up .obsidian/ configs (plugins, themes, etc)
    # but NOT the sync state database
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
fi

# Ensure remote is configured (handles partial-init recovery)
if ! git remote get-url origin &>/dev/null; then
    git remote add origin "${GIT_REMOTE_URL}"
    log "[git] Git repo initialized with remote: ${GIT_REMOTE_URL}"
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
    log "[git] No changes to commit."
else
    git commit -m "$MSG"
    log "[git] Committed changes."
    log "[git] Pushing to ${GIT_BRANCH:-main}..."
    git push -u origin "${GIT_BRANCH:-main}"
    log "[git] Push complete."
fi
