#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

VAULT_PATH="/vault"
FIRST_RUN_MARKER="$VAULT_PATH/.obsidian/.vault-backup-initialized"

# ── Validate required env vars ────────────────────
if [[ -z "${OBSIDIAN_AUTH_TOKEN:-}" ]]; then
    log "[error] OBSIDIAN_AUTH_TOKEN is not set. Run 'ob login' locally and copy the token."
    exit 1
fi

if [[ -z "${VAULT_NAME:-}" ]]; then
    log "[error] VAULT_NAME is not set. Set it to your remote vault name."
    exit 1
fi

# ── First-run setup ───────────────────────────────
if [[ ! -f "$FIRST_RUN_MARKER" ]]; then
    log "[init] First run detected. Setting up sync..."

    # Link local vault to remote
    ob sync-setup \
        --vault "${VAULT_NAME}" \
        --path "$VAULT_PATH" \
        ${E2EE_PASSWORD:+--password "$E2EE_PASSWORD"} \
        --device-name "${DEVICE_NAME:-vault-backup}" \
        --config-dir "${CONFIG_DIR:-.obsidian}"

    # Configure sync mode (default mirror-remote for backup safety)
    sync_config_args=(--path "$VAULT_PATH" --mode "${SYNC_MODE:-mirror-remote}")
    [[ -n "${CONFLICT_STRATEGY:-}" ]]    && sync_config_args+=(--conflict-strategy "$CONFLICT_STRATEGY")
    [[ -n "${SYNC_FILE_TYPES:-}" ]]      && sync_config_args+=(--file-types "$SYNC_FILE_TYPES")
    [[ -n "${SYNC_CONFIGS:-}" ]]         && sync_config_args+=(--configs "$SYNC_CONFIGS")
    [[ -n "${SYNC_EXCLUDED_FOLDERS:-}" ]] && sync_config_args+=(--excluded-folders "$SYNC_EXCLUDED_FOLDERS")
    ob sync-config "${sync_config_args[@]}"

    mkdir -p "$VAULT_PATH/.obsidian"
    touch "$FIRST_RUN_MARKER"
    log "[init] Setup complete."
fi

# ── Sync ──────────────────────────────────────────
# Work around stale sync lock left by sync-setup or previous hard-killed syncs.
# obsidian-headless uses an mtime-based lock at .obsidian/.sync.lock that can
# fail to release due to an mtime race condition. The lock expires after 5s,
# but back-to-back commands hit it before expiry.
# See: https://github.com/obsidianmd/obsidian-headless/issues/4
SYNC_LOCK="$VAULT_PATH/.obsidian/.sync.lock"
if [[ -d "$SYNC_LOCK" ]]; then
    log "[sync] Removing stale sync lock."
    rm -rf "$SYNC_LOCK"
fi
sleep 5

log "[sync] Starting Obsidian Sync..."
timeout "${SYNC_TIMEOUT:-600}" ob sync --path "$VAULT_PATH"
log "[sync] Sync complete."

# ── Backup ────────────────────────────────────────
BACKUP_PROVIDER="${BACKUP_PROVIDER:-git}"

case "$BACKUP_PROVIDER" in
    git)
        source /usr/local/bin/backup-git.sh
        ;;
    s3)
        log "[backup] s3 provider not yet implemented"
        exit 1
        ;;
    rsync)
        log "[backup] rsync provider not yet implemented"
        exit 1
        ;;
    none)
        log "[backup] No backup provider configured. Skipping."
        ;;
    *)
        log "[error] Unknown BACKUP_PROVIDER: $BACKUP_PROVIDER"
        exit 1
        ;;
esac

log "[done] Vault backup complete."

# ── Healthcheck ping ─────────────────────────────
if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
    if ! curl -fsS --max-time 10 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
        log "[warn] Healthcheck ping to $HEALTHCHECK_URL failed."
    fi
fi
