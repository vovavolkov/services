#!/bin/bash
#
# Restore Paperless-ngx from a backup made by scripts/paperlessbackup.sh.
#
# The archive holds the output of document_exporter, so restoring is an import,
# not a file copy -- and paperless only imports cleanly into an empty instance.
# This therefore destroys the current database and media volumes first.
#
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"

PAPERLESS_DIR="${PAPERLESS_DIR:-$SERVICES_DIR/paperless-ngx}"
EXPORT_PARENT="${EXPORT_PARENT:-/opt/docker/paperless-ngx}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-y] <archive|datestamp>

  Restores Paperless-ngx from a paperless_*.tar.gz backup.
  Accepts a full path, a filename, or just the date (e.g. 20260823).

  WARNING: this deletes the current paperless database and media volumes.
  Anything not in the archive is lost. Run scripts/paperlessbackup.sh first
  if the current state still matters.

  -y, --yes   skip the confirmation prompt (for unattended use)

$(list_archives paperless)
USAGE
}

parse_flags "$@"
(( ${#ARGS[@]} == 1 )) || { usage; exit 1; }
need_cmd docker; need_cmd python3

ARCHIVE="$(resolve_archive "${ARGS[0]}" paperless)"
[[ -d "$PAPERLESS_DIR" ]] || die "no such directory: $PAPERLESS_DIR"

verify_archive "$ARCHIVE"

# Read the listing into a variable rather than piping tar into grep: grep exits
# as soon as it matches, tar dies on SIGPIPE, and `set -o pipefail` then reports
# the whole pipeline as failed even though the match succeeded.
info "Checking this is a document_exporter export"
LISTING="$(tar -tzf "$ARCHIVE")"
grep -Fq 'export/manifest.json' <<<"$LISTING" \
    || die "$ARCHIVE has no export/manifest.json -- not a document_exporter archive"
info "Archive holds $(grep -c . <<<"$LISTING") entries"

PROJECT="$(compose_project "$PAPERLESS_DIR")"
VOLUMES=("${PROJECT}_data" "${PROJECT}_media" "${PROJECT}_pgdata")
info "Compose project: $PROJECT"
info "Volumes to be destroyed: ${VOLUMES[*]}"

confirm "This will DELETE the volumes ${VOLUMES[*]} and re-import from $(basename "$ARCHIVE")."

cd "$PAPERLESS_DIR"

info "Stopping the stack"
docker compose down

info "Replacing $EXPORT_PARENT/export with the archive contents"
rm -rf "${EXPORT_PARENT:?}/export"
tar -xzf "$ARCHIVE" -C "$EXPORT_PARENT"
[[ -f "$EXPORT_PARENT/export/manifest.json" ]] || die "manifest.json missing after unpack"

info "Removing the old data volumes"
for v in "${VOLUMES[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
        docker volume rm "$v" >/dev/null \
            || die "could not remove volume $v -- check 'docker ps -a' for leftover containers"
        info "  removed $v"
    else
        info "  $v does not exist, skipping"
    fi
done

info "Starting the stack empty so it can build its schema"
docker compose up -d
wait_healthy "$PAPERLESS_DIR" webserver

info "Importing documents (this takes a while for a large archive)"
docker compose exec -T webserver document_importer ../export

cat <<DONE

Restore complete.

  Open https://paperless.vovavolkov.com and confirm the document count looks right.
DONE
