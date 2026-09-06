# Changelog

All notable changes to this project are documented here.

Versioning uses [CalVer](https://calver.org/) in the form `YYYY.0W.0`
(four-digit year, zero-padded ISO week, patch counter) — see the
Versioning section in `CLAUDE.md`.

## [Unreleased]

## [2026.36.0] - 2026-09-06

First tagged release. Consolidates all work done since the project's
initial commit.

### Added

- Containerized `obsidian-headless` sync tool with git backup, built for
  one-shot execution under a Kubernetes CronJob or host cron.
- Git backup provider: init, commit-on-change, and push, with `s3` and
  `rsync` providers stubbed for future use.
- First-run detection via a marker file so initial vault setup only
  happens once.
- Optional `HEALTHCHECK_URL` dead-man's-switch ping on successful runs.
- Flat Kubernetes manifests (Namespace, PVC, ConfigMap, CronJob) with a
  choice of plain `Secret` or 1Password Connect item for credentials.

### Fixed

- First-run crash and hardened K8s manifest security context.
- Stale sync lock left behind by `obsidian-headless` (upstream
  [issue #4](https://github.com/obsidianmd/obsidian-headless/issues/4)),
  including cleanup after sync and later dropping the workaround once no
  longer needed.
- Dubious ownership git error on PVC mounts by setting `safe.directory`.
- `backup-git.sh` hardened for all PVC state scenarios (fresh, partial,
  and existing clones).
- Rejected push on a fresh PVC by fetching remote history first.
- Raised inotify limits for large vaults.

### Changed

- Bumped `obsidian-headless` from 0.0.6 through 0.0.14 (see upstream
  [releases](https://github.com/obsidianmd/obsidian-headless/releases)),
  including fixes for a WebSocket reconnect hang, a sync-filter bug that
  could delete remote files, and `.obsidian` config not loading properly.
- Dropped `readOnlyRootFilesystem` — `obsidian-headless`, git, and Node.js
  all need to write to the home directory; security instead comes from
  non-root + no privilege escalation + dropped capabilities.

[Unreleased]: https://github.com/ShakataGaNai/obsidian-headless-backup/compare/v2026.36.0...HEAD
[2026.36.0]: https://github.com/ShakataGaNai/obsidian-headless-backup/releases/tag/v2026.36.0
