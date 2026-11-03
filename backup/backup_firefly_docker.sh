#!/bin/bash
#
# Firefly III backup: MariaDB dump + uploads, verified, checksummed, rotated.
#
# Credentials come from the same .db.env the DB container uses, so there is
# exactly one copy of the password on disk. Nothing is hardcoded here.
#
# Layout inside the archive:
#   fireflyiii_YYYYMMDD/database.sql
#   fireflyiii_YYYYMMDD/uploads/
#
set -euo pipefail

FIREFLY_DIR="${FIREFLY_DIR:-/home/vova/services/fireflyiii}"
BACKUP_DIR="${BACKUP_DIR:-/home/vova/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-6}"
DB_CONTAINER="${DB_CONTAINER:-firefly_iii_db}"
APP_CONTAINER="${APP_CONTAINER:-firefly_iii_core}"

DB_ENV_FILE="$FIREFLY_DIR/.db.env"
if [[ ! -r "$DB_ENV_FILE" ]]; then
    echo "ERROR: cannot read $DB_ENV_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$DB_ENV_FILE"; set +a
DB_USER="${MYSQL_USER:?MYSQL_USER not set in $DB_ENV_FILE}"
DB_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD not set in $DB_ENV_FILE}"
DB_NAME="${MYSQL_DATABASE:?MYSQL_DATABASE not set in $DB_ENV_FILE}"

# MYSQL_PWD keeps the password out of the container's argv, where any user on
# the box could read it via `docker top` / ps.
mariadb_exec() { docker exec -e MYSQL_PWD="$DB_PASSWORD" -i "$DB_CONTAINER" "$@"; }

# === VALIDATE CREDENTIALS ===
if ! mariadb_exec mariadb -u "$DB_USER" -e "SHOW DATABASES;" >/dev/null 2>&1; then
    echo "ERROR: cannot connect to $DB_CONTAINER as '$DB_USER' with the password from $DB_ENV_FILE" >&2
    exit 1
fi

# === SETUP ===
DATE="$(date +%Y%m%d)"
NAME="fireflyiii_${DATE}"
ARCHIVE="$BACKUP_DIR/${NAME}.tar.gz"
CHECKSUM="$ARCHIVE.sha256"

mkdir -p "$BACKUP_DIR"
STAGE_ROOT="$(mktemp -d "$BACKUP_DIR/.stage.XXXXXX")"
VERIFY_DIR="$(mktemp -d "$BACKUP_DIR/.verify.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT" "$VERIFY_DIR"' EXIT
PAYLOAD="$STAGE_ROOT/$NAME"
mkdir -p "$PAYLOAD"

# === DATABASE BACKUP ===
echo "Creating database backup..."
mariadb_exec mariadb-dump -u "$DB_USER" "$DB_NAME" > "$PAYLOAD/database.sql"

# === UPLOADS BACKUP ===
echo "Creating uploads backup..."
docker cp "$APP_CONTAINER:/var/www/html/storage/upload" "$PAYLOAD/uploads"

# === COMPRESS ===
echo "Compressing backup..."
tar -czf "$ARCHIVE" -C "$STAGE_ROOT" "$NAME"

# === VERIFY ===
echo "Verifying backup..."
tar -xzf "$ARCHIVE" -C "$VERIFY_DIR"

if [[ ! -s "$VERIFY_DIR/$NAME/database.sql" ]]; then
    echo "ERROR: Database dump is empty or missing!" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

echo "Checking database content..."
REQUIRED_TABLES=("users" "accounts" "transactions")
for table in "${REQUIRED_TABLES[@]}"; do
    if ! grep -q "CREATE TABLE \`$table\`" "$VERIFY_DIR/$NAME/database.sql"; then
        echo "ERROR: Required table '$table' not found in database dump!" >&2
        rm -f "$ARCHIVE"
        exit 1
    fi
done

if [[ ! -d "$VERIFY_DIR/$NAME/uploads" ]]; then
    echo "ERROR: Uploads directory is missing!" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

# === CHECKSUM ===
echo "Calculating checksums..."
( cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")" )

# === ROTATE (keep newest $MAX_BACKUPS) ===
mapfile -t STALE < <(ls -1t "$BACKUP_DIR"/fireflyiii_*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))
if (( ${#STALE[@]} > 0 )); then
    for old in "${STALE[@]}"; do
        echo "Pruning old backup: $(basename "$old")"
        rm -f -- "$old" "$old.sha256"
    done
fi

echo "Backup verification completed successfully!"
echo "Backup file:   $ARCHIVE"
echo "Checksum file: $CHECKSUM"
echo "Retention:     newest $MAX_BACKUPS kept in $BACKUP_DIR"
