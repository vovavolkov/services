#!/bin/bash
#
# Restore the AdGuard Home settings from a backup made by
# backup/backup_adguard.sh.
#
# Replaces AdGuardHome.yaml in the config volume. Query logs and statistics
# (work volume) are untouched.
#
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"

ADGUARD_CONTAINER="${ADGUARD_CONTAINER:-adguardhome-adguardhome-1}"
CONF_PATH="${CONF_PATH:-/opt/adguardhome/conf/AdGuardHome.yaml}"
ADMIN_ADDR="${ADMIN_ADDR:-127.0.0.1:15000}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-y] [--dry-run] [backup-file|datestamp]

  Restores the AdGuard Home settings from an adguard_*.yaml backup.
  Accepts a full path, a filename, or just the date (e.g. 20261101).
  Defaults to the newest backup.

  --dry-run   verify the backup and show what would happen, change nothing
  -y, --yes   skip the confirmation prompt (for unattended use)

Available in $BACKUP_DIR:
$(ls -1r "$BACKUP_DIR"/adguard_*.yaml 2>/dev/null | sed 's/^/  /' || echo '  (none)')
USAGE
}

DRY_RUN=0
FILTERED=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        *) FILTERED+=("$a") ;;
    esac
done
parse_flags ${FILTERED[@]+"${FILTERED[@]}"}
(( ${#ARGS[@]} <= 1 )) || { usage; exit 1; }
need_cmd docker; need_cmd sha256sum

if (( ${#ARGS[@]} == 0 )); then
    FILE="$(ls -1r "$BACKUP_DIR"/adguard_*.yaml 2>/dev/null | head -n 1 || true)"
    [[ -n "$FILE" ]] || die "no adguard_*.yaml found in $BACKUP_DIR"
else
    FILE=""
    for c in "${ARGS[0]}" "$BACKUP_DIR/${ARGS[0]}" "$BACKUP_DIR/adguard_${ARGS[0]}.yaml"; do
        [[ -f "$c" ]] && { FILE="$c"; break; }
    done
    [[ -n "$FILE" ]] || die "no backup found for '${ARGS[0]}' (looked in $BACKUP_DIR for adguard_*.yaml)"
fi

# === VERIFY ===
[[ -s "$FILE" ]] || die "$FILE is empty"
grep -q '^dns:' "$FILE" && grep -q '^filters:' "$FILE" || die "$FILE does not look like an AdGuardHome.yaml"
if [[ -f "$FILE.sha256" ]]; then
    info "Verifying checksum"
    want="$(awk '{print $1; exit}' "$FILE.sha256")"
    [[ ${#want} -eq 64 ]] || die "malformed checksum file: $FILE.sha256"
    got="$(sha256sum "$FILE" | awk '{print $1}')"
    [[ "$want" == "$got" ]] || die "checksum mismatch on $FILE -- do not restore this
       expected $want
       got      $got"
    info "Checksum OK ($got)"
else
    warn "No .sha256 alongside $FILE; restoring without an integrity check"
fi

if (( DRY_RUN )); then
    info "Dry run: would restore $FILE"
    info "Dry run: would stop container $ADGUARD_CONTAINER"
    info "Dry run: would docker cp the file to $ADGUARD_CONTAINER:$CONF_PATH"
    info "Dry run: would start $ADGUARD_CONTAINER and check http://$ADMIN_ADDR inside it"
    if docker cp "$ADGUARD_CONTAINER:$CONF_PATH" - 2>/dev/null | tar -xO 2>/dev/null | cmp -s - "$FILE"; then
        info "Dry run: the live config is identical to this backup"
    else
        info "Dry run: the live config differs from this backup"
    fi
    exit 0
fi

confirm "This will overwrite the live AdGuard Home settings with $(basename "$FILE")."

info "Stopping $ADGUARD_CONTAINER"
docker stop "$ADGUARD_CONTAINER" >/dev/null

info "Copying settings into the config volume"
docker cp "$FILE" "$ADGUARD_CONTAINER:$CONF_PATH"

info "Starting $ADGUARD_CONTAINER"
docker start "$ADGUARD_CONTAINER" >/dev/null

info "Waiting for AdGuard Home to answer on $ADMIN_ADDR"
waited=0
until docker exec "$ADGUARD_CONTAINER" wget -q -O /dev/null "http://$ADMIN_ADDR/" 2>/dev/null; do
    (( waited < 60 )) || die "AdGuard Home did not answer within 60s (check: docker logs $ADGUARD_CONTAINER)"
    sleep 3; waited=$((waited + 3))
done
state="$(docker inspect --format '{{.State.Status}}' "$ADGUARD_CONTAINER")"
[[ "$state" == "running" ]] || die "container is $state, expected running"

cat <<DONE

Restore complete.

  Container is running and the admin interface answers. Open the AdGuard Home
  web UI and check that filters, clients and DNS settings are as expected.
DONE
