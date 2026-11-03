# Restoring backups

Every restore is a script in [`restore/`](restore/). Run them on `vovaserver`. They all
take the backup you want, prompt before destroying anything, and print what to
check afterwards.

```bash
cd ~/services/restore
./restore-firefly.sh                 # no arguments -> usage + list of available backups
./restore-firefly.sh 20260801        # restore that backup
./restore-firefly.sh -y 20260801     # skip the confirmation prompt
```

| Service | Restore with | Accepts |
|---|---|---|
| Firefly III | `restore/restore-firefly.sh` | date stamp, filename, or path |
| Paperless-ngx | `restore/restore-paperless.sh` | date stamp, filename, or path |
| AdGuard Home settings | `restore/restore-adguard.sh` | filename, path, date stamp, or nothing for the newest |
| Minecraft survival world | `restore/restore-minecraft.sh` | `latest`, a snapshot name, or a legacy `.tar.gz` |
| Syncthing `uni` folder | `restore/restore-uni-sync.sh` | date stamp, filename, or path |

Shared helpers live in `restore/common.sh`; it is sourced, not run.

Paths are overridable by environment variable (`BACKUP_DIR`, `SERVICES_DIR`,
`MC_DATA`, `UNI_DIR`, …) so the scripts can be pointed at a scratch copy for a
rehearsal instead of the live service.

## What exists, and how it is made

| What | Produced by | Schedule | Format in `~/backups` | Retention |
|---|---|---|---|---|
| Firefly III | `backup/backup_firefly_docker.sh` | cron, 04:00 on the 1st | `fireflyiii_YYYYMMDD.tar.gz` + `.sha256` | newest 3 |
| Paperless-ngx | `backup/paperlessbackup.sh` → `backup/backup.sh` | cron, 03:00 on the 1st | `paperless_YYYYMMDD.tar.gz` | newest 2 |
| Syncthing `uni` folder | `backup/backup.sh` | cron, 03:00 Sunday | `uni-sync_YYYYMMDD.tar.gz` | newest 2 |
| Syncthing `org`, `life` (encrypted) | `backup/backup.sh` | cron, 03:10 / 03:20 Sunday | `org-enc_YYYYMMDD.tar.gz`, `life-enc_YYYYMMDD.tar.gz` | newest 2 |
| AdGuard Home settings | `backup/backup_adguard.sh` | cron, 03:30 on the 1st | `adguard_YYYYMMDD.yaml` + `.sha256` | newest 3 |
| Minecraft survival world | `mc-backup` side-car in `mc-survival/docker-compose.yaml` | 04:00 daily, in-container cron | `mc-survival/mc-survival-YYYYMMDD-HHMMSS/` (directories) | newest 5 |

The backup scripts live in [`backup/`](backup/) and the restore scripts in
[`restore/`](restore/), both in git, deliberately — they are what you need
after losing the box. See [BACKUPS.md](BACKUPS.md) for the whole routine.

## Checksum files are not all the same thing

- `fireflyiii_*.tar.gz.sha256` — a **real integrity checksum of the archive**.
  The restore script verifies it and refuses to continue on a mismatch.
- `paperless.checksum`, `uni-sync.checksum` — written
  by `backup.sh`, these hold an md5 of the **source tree at backup time**. They
  exist so the next run can skip work when nothing changed. They **cannot**
  verify an archive. For those the restore scripts fall back to `tar -tzf`,
  which at least proves the archive is not truncated.

## Things worth knowing before you need them

**Firefly archives changed layout.** Backups from 2026-09 onward unpack to
`fireflyiii_YYYYMMDD/`; older ones have an extra `backups/` directory on top.
`restore-firefly.sh` locates `database.sql` rather than assuming a depth, so it
handles both without being told which is which.

**Restoring Paperless destroys the current instance.** The archive is
`document_exporter` output, and paperless only imports cleanly into an empty
instance, so `restore-paperless.sh` deletes the database and media volumes
before importing. Run `backup/paperlessbackup.sh` first if the current state
still matters. The compose project is named `paperless`, not `paperless-ngx`
after its directory — the script reads the real name from
`docker compose config` rather than guessing the volume prefix.

**Pause Syncthing before restoring `uni`.** Otherwise Syncthing propagates the
restored files to every peer as soon as they land. That is what you want if the
loss was local, and very much not what you want if you are recovering from
something that already synced everywhere. Use
`restore-uni-sync.sh --diff-only <archive>` to see what would change without
writing anything. The restore runs `rsync` without `--delete`, so files present
now but absent from the backup survive.

**AdGuard restores settings only.** `restore-adguard.sh [file]` (default: newest `adguard_*.yaml`) verifies the `.sha256`, stops `adguardhome-adguardhome-1`, copies the file over `AdGuardHome.yaml` in the config volume, starts the container and checks that the admin interface answers inside it. Query logs and statistics are not part of the backup. `--dry-run` verifies the file and prints the steps without changing anything.

**Minecraft restores keep the old world.** `restore-minecraft.sh` moves the
current world to `world.before-restore-<timestamp>` instead of deleting it, and
prints the path. Remove it by hand once you have logged in and confirmed.

There is no `restore-rsync-backup` init container in the Minecraft compose file
on purpose: that helper only fires when `/data` is completely empty, and `/data`
here always contains the mods `mc-setup` downloads, so it would never trigger.

**Ad-hoc Minecraft backup**, without waiting for 04:00:

```bash
docker compose -f ~/services/mc-survival/docker-compose.yaml exec mc-backup backup now
```

## Encrypted org and life

The archives hold Syncthing-encrypted data. Decrypt with the folder password from Bitwarden on any machine with Syncthing:

```sh
mkdir enc && tar -xzf ~/backups/life-enc_YYYYMMDD.tar.gz -C enc
syncthing decrypt --password '<folder password>' --to life-restored enc/life
```

`--to` gets the plaintext tree. The same works for `org-enc`.

## Restoring onto a different machine

The compose files in this repository are the other half of every restore: the
archives hold data, not configuration. To rebuild from scratch you also need the
`.env` files, which are **not** in git (`.gitignore` excludes `*.env`) and are
**not** in any of these backups:

- `fireflyiii/.env`, `fireflyiii/.db.env`, `fireflyiii/.importer.env`
- `paperless-ngx/docker-compose.env`

Only the `.template` versions are committed. Without the real ones the Firefly
`APP_KEY` is gone and existing encrypted values cannot be read, so keep a copy
of those four files somewhere outside this box.

## If a script itself needs rolling back

The backup scripts and a copy of the crontab (`backup/crontab.txt`) are in this
repo. Roll back with git, then reinstall the crontab with
`crontab backup/crontab.txt`.
