# Backups

Overview of the whole backup routine. Restore procedures are in [RESTORE.md](RESTORE.md) and the scripts in [`restore/`](restore/).

## What is backed up

| What | Produced by | Output in `~/backups` (server) |
|---|---|---|
| Syncthing `uni` folder (`/home/vova/Syncthing/uni`) | `backup/backup.sh` | `uni-sync_YYYYMMDD.tar.gz`, `uni-sync.checksum` |
| Syncthing `org` and `life` folders, stored encrypted (`/home/vova/Syncthing/org`, `/home/vova/Syncthing/life`) | `backup/backup.sh` | `org-enc_YYYYMMDD.tar.gz`, `life-enc_YYYYMMDD.tar.gz` + `.checksum` |
| Paperless-ngx | `backup/paperlessbackup.sh` (runs `document_exporter`, then `backup.sh` on the export dir) | `paperless_YYYYMMDD.tar.gz`, `paperless.checksum` |
| Firefly III (MariaDB dump + uploads) | `backup/backup_firefly_docker.sh` | `fireflyiii_YYYYMMDD.tar.gz` + `.sha256` |
| AdGuard Home settings (`AdGuardHome.yaml` from the `adguardhome_config` volume; query logs and stats in the work volume are not backed up) | `backup/backup_adguard.sh` | `adguard_YYYYMMDD.yaml` + `.sha256` (mode 600, contains the admin password hash) |
| Minecraft survival world | `mc-backup` side-car in `mc-survival/docker-compose.yaml` (not cron) | `mc-survival/mc-survival-YYYYMMDD-HHMMSS/` (rsync directories), daily 04:00, newest 5 kept |

Archived Minecraft world: the world played with my girlfriend (vanilla, then Fabric 1.21.8; last played 24 Jan 2026) is kept permanently as `~/backups/archive/mc-gf-world-20260124.tar.gz` (+ `.sha256`). It is a ready-to-run package: `docker-compose.yaml` (itzg/minecraft-server pinned to the original Minecraft, Fabric and mod versions), a `README.md`, and `data/` (world, config, server.properties, whitelist). A verified copy is in `~/backups/archive/` on the Mac. `archive/` is never rotated by any script. Restore: extract anywhere with Docker and run `docker compose up -d`.

## Schedule (server, user `vova`)

Exact copy in [`backup/crontab.txt`](backup/crontab.txt):

```
0 3 * * 0 /home/vova/services/backup/backup.sh /home/vova/Syncthing/uni uni-sync > /dev/null 2>&1
10 3 * * 0 /home/vova/services/backup/backup.sh /home/vova/Syncthing/org org-enc > /dev/null 2>&1
20 3 * * 0 /home/vova/services/backup/backup.sh /home/vova/Syncthing/life life-enc > /dev/null 2>&1
0 3 1 * * /home/vova/services/backup/paperlessbackup.sh
0 4 1 * * /home/vova/services/backup/backup_firefly_docker.sh
30 3 1 * * /home/vova/services/backup/backup_adguard.sh
```

- uni-sync: Sundays 03:00
- org-enc, life-enc: Sundays 03:10 and 03:20
- Paperless: 1st of the month, 03:00
- Firefly III: 1st of the month, 04:00
- AdGuard Home: 1st of the month, 03:30

The crontab itself is not read from git. After editing `backup/crontab.txt`, install it with `crontab` (note it contains only the job lines, no comment header).

## Where tarballs go and how they rotate

All on the server in `/home/vova/backups`.

- `backup.sh <source_path> <name>`: computes an md5 over all files in the source; if it matches `<name>.checksum` the backup is skipped ("No changes detected"). Otherwise it writes `<name>_YYYYMMDD.tar.gz`, updates the checksum file and keeps the newest 2 tarballs (`MAX_BACKUPS=2`). The checksum file is a hash of the source tree, not of the archive.
- `paperlessbackup.sh`: exports into `/opt/docker/paperless-ngx/export` with `document_exporter -d` (snapshot, deleted docs removed), then calls `backup.sh` on that directory with name `paperless`. Newest 2 kept; skipped if nothing changed.
- `backup_firefly_docker.sh`: dumps MariaDB (`firefly_iii_db`) and copies uploads from `firefly_iii_core`, tars them, verifies the archive (non-empty dump, tables `users`, `accounts`, `transactions`, uploads dir), writes a real `.sha256` of the archive and keeps the newest 3 (`MAX_BACKUPS`).
- `backup_adguard.sh`: copies `AdGuardHome.yaml` out of `adguardhome-adguardhome-1` with `docker cp`, checks it is non-empty and has the top-level keys `dns:`, `filters:` and `users:`, writes a `.sha256`, and keeps the newest 3 (`MAX_BACKUPS`). If the config is identical (same sha256) to the newest existing backup, nothing new is written. Restore: `restore/restore-adguard.sh` (see RESTORE.md).
- Credentials: the Firefly script reads `MYSQL_*` from `fireflyiii/.db.env` (not committed). No secrets are hardcoded in any script.
- Paths are overridable by environment variable (`BACKUP_DIR`, `FIREFLY_DIR`, `ADGUARD_CONTAINER`, `PAPERLESS_DIR`, `EXPORT_DIR`, `BACKUP_SCRIPT`).

## Mac pull (off-site copy)

`/Users/vova/backups/copyBackups.sh` on the Mac, run from the Mac crontab:

```
0 5 * * 1 /Users/vova/backups/copyBackups.sh
```

Mondays 05:00. It connects by ssh to `vovaserver` as `vova`, picks the newest of each of these in `/home/vova/backups`, and rsyncs them to `~/backups` on the Mac:

- `paperless_*.tar.gz` (Mac keeps newest 3)
- `fireflyiii_*.tar.gz` (Mac keeps newest 3)
- `uni-sync_*.tar.gz` (Mac keeps newest 3, about 1.1 GB each; Syncthing is sync not backup, so these protect against deletions spreading)
- `adguard_*.yaml` plus its `.sha256` (Mac keeps newest 3)
- the newest `mc-survival/mc-survival-YYYYMMDD-HHMMSS/` directory, rsynced with `--delete` into a single mirror directory `~/backups/mc-survival-latest/`, so the Mac holds exactly one Minecraft backup. If the server has no such directory, the step is skipped with a message.

The script is Mac-only and is not in this repo. The Mac must be on and able to reach `vovaserver` at that time.

The Minecraft side-car prunes to the newest 5 daily backups on the server; the Mac mirror always holds only the newest. The archived world is kept separately in `archive/`.

## Webhook

The `webhook` service (hooks that start and stop Minecraft stacks and publish to MQTT) is documented in [webhook/README.md](webhook/README.md). The repo holds a copy of its hooks, scripts and unit file; the live files are in `/etc/webhook`, `/var/scripts` and `/etc/systemd/system`.

## Configs

- Stack configuration (compose files, restore and backup scripts, docs) is this git repo, remote `git@github.com:vovavolkov/services.git`.
- Secrets live in `*.env` files next to each compose file and are gitignored. Keep a copy of them outside the server (see RESTORE.md, Firefly `APP_KEY`).
- Runtime data (`mc-survival/.data/`, `pingvin/data/`) is gitignored and covered only by the backups above where listed.

## Restore

## Encrypted folders (org, life)

`~/org` and `~/life` on the Mac are shared with this server as Syncthing untrusted devices: the server holds only encrypted file names and contents (`*.syncthing-enc`) and never sees the password. The weekly tarballs therefore contain encrypted data. The folder password is in Bitwarden. Not pulled to the Mac (the Mac holds the plaintext originals).

See [RESTORE.md](RESTORE.md) and the per-service scripts in [`restore/`](restore/) (`restore-firefly.sh`, `restore-adguard.sh`, `restore-paperless.sh`, `restore-minecraft.sh`, `restore-uni-sync.sh`).

## Pushing from the server

The server pushes directly with a deploy key: `~/.ssh/services_deploy` (ed25519), added to the GitHub repo under Settings > Deploy keys with write access. The repo uses it via `git config core.sshCommand "ssh -i ~/.ssh/services_deploy -o IdentitiesOnly=yes"`, so plain `git push` / `git pull` work on the server. The key only has access to this repo.

## Updating stacks

In each stack directory:

```
docker compose pull && docker compose up -d
```
