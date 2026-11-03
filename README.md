# services

Docker Compose stacks for my homelab, a small Linux box (`vovaserver`) reachable over Tailscale.

| Stack | What it is | Exposure |
|---|---|---|
| [caddy](caddy/) | Reverse proxy and TLS for everything below. Certificates via the Cloudflare DNS challenge, so private hostnames get real certificates without being reachable from the internet. | Public site + Tailnet |
| [adguardhome](adguardhome/) | Network-wide DNS resolver with ad and tracker blocking. | Tailnet |
| [fireflyiii](fireflyiii/) | Personal finance manager (Firefly III, MariaDB, data importer, cron). | Tailnet |
| [paperless-ngx](paperless-ngx/) | Document archive with OCR (Paperless-ngx, PostgreSQL, Redis, Gotenberg, Tika). | Tailnet |
| [readeck](readeck/) | Read-it-later and bookmark archive. | Tailnet |
| [mealie](mealie/) | Recipe manager. | Tailnet |
| [pingvin](pingvin/) | Self-hosted file sharing. | Public |
| [mc-survival](mc-survival/) | Modded Fabric Minecraft server with a worldgen merge step and an RCON-aware backup side-car. | Tailnet |

## Layout

- Web services bind to `127.0.0.1` and are reached through Caddy, which serves private hostnames only on the Tailscale interface. The Minecraft server listens on the Tailscale IP directly.
- Secrets live in `.env` files next to each compose file and are not committed. Each stack that needs them has a `*.env.template` showing the expected variables.
- Persistent data is in named volumes or bind mounts under `/opt/docker`.

## Backups and restore

Backups run from cron (Firefly III, Paperless-ngx) and from the `mc-backup` side-car (Minecraft). [RESTORE.md](RESTORE.md) explains what is backed up and how to restore each service with the scripts in [`restore/`](restore/).

The whole routine (what, when, where, Mac pull, updating stacks) is documented in [BACKUPS.md](BACKUPS.md).
