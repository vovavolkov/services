#!/bin/bash
#
# Paperless-ngx backup: run document_exporter into the host-mounted export
# directory, then hand that directory to the generic backup script.
#
set -euo pipefail

PAPERLESS_DIR="${PAPERLESS_DIR:-/home/vova/services/paperless-ngx}"
EXPORT_DIR="${EXPORT_DIR:-/opt/docker/paperless-ngx/export}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/home/vova/services/backup/backup.sh}"

cd "$PAPERLESS_DIR"

# -d removes exported files that no longer exist in the database, so the export
# stays a snapshot instead of accumulating deleted documents forever.
# ../export is relative to the container's workdir (/usr/src/paperless).
docker compose exec -T webserver document_exporter -d ../export

"$BACKUP_SCRIPT" "$EXPORT_DIR" paperless
