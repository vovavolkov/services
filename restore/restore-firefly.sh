#!/bin/bash
#
# Restore Firefly III from a backup made by backup/backup_firefly_docker.sh.
#
# Replaces the database and the uploads volume with the contents of the archive.
#
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"

FIREFLY_DIR="${FIREFLY_DIR:-$SERVICES_DIR/fireflyiii}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-y] <archive|datestamp>

  Restores Firefly III from a fireflyiii_*.tar.gz backup.
  Accepts a full path, a filename, or just the date (e.g. 20260801).

  -y, --yes   skip the confirmation prompt (for unattended use)

$(list_archives fireflyiii)
USAGE
}

parse_flags "$@"
(( ${#ARGS[@]} == 1 )) || { usage; exit 1; }
need_cmd docker; need_cmd sha256sum

ARCHIVE="$(resolve_archive "${ARGS[0]}" fireflyiii)"
[[ -d "$FIREFLY_DIR" ]] || die "no such directory: $FIREFLY_DIR"
[[ -r "$FIREFLY_DIR/.db.env" ]] || die "cannot read $FIREFLY_DIR/.db.env"

verify_archive "$ARCHIVE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info "Unpacking $(basename "$ARCHIVE")"
tar -xzf "$ARCHIVE" -C "$WORK"

# Archives made before 2026-09 have an extra top-level backups/ directory, so
# locate the payload rather than assuming a fixed depth.
DUMP="$(find "$WORK" -type f -name database.sql -print -quit)"
[[ -n "$DUMP" ]] || die "no database.sql inside $ARCHIVE"
PAYLOAD="$(dirname "$DUMP")"
UPLOADS="$PAYLOAD/uploads"
[[ -d "$UPLOADS" ]] || die "no uploads/ directory inside $ARCHIVE"
info "Payload: ${PAYLOAD#"$WORK"/}  ($(wc -l < "$DUMP") lines of SQL, $(du -sh "$UPLOADS" | cut -f1) of uploads)"

set -a; . "$FIREFLY_DIR/.db.env"; set +a
: "${MYSQL_USER:?not set in .db.env}" "${MYSQL_PASSWORD:?not set in .db.env}" "${MYSQL_DATABASE:?not set in .db.env}"

confirm "This will DROP the '$MYSQL_DATABASE' database and erase the current Firefly uploads."

cd "$FIREFLY_DIR"

info "Stopping app, importer and cron (leaving the database up)"
docker compose stop app importer cron

mariadb_exec() { docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" -i firefly_iii_db "$@"; }

# Recreate the schema from scratch. The dump only recreates the tables it
# contains, so without this a restore can leave stale tables behind.
info "Recreating database '$MYSQL_DATABASE'"
mariadb_exec mariadb -u "$MYSQL_USER" \
    -e "DROP DATABASE \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`;"

info "Loading dump"
mariadb_exec mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE" < "$DUMP"

info "Starting app"
docker compose up -d app
wait_healthy "$FIREFLY_DIR" app

info "Restoring uploads"
docker exec firefly_iii_core sh -c 'rm -rf /var/www/html/storage/upload/*'
docker cp "$UPLOADS/." firefly_iii_core:/var/www/html/storage/upload/
docker exec firefly_iii_core chown -R www-data:www-data /var/www/html/storage/upload

info "Starting the rest of the stack"
docker compose up -d

cat <<DONE

Restore complete.

  Open https://firefly.vovavolkov.com and check that transactions and attachments
  are present.

  If the archive predates the running image's schema, Firefly will ask to
  migrate. Run:
    docker compose -f $FIREFLY_DIR/docker-compose.yml exec app \\
      php artisan firefly-iii:upgrade-database
DONE
