#!/bin/bash
#
# AdGuard Home settings backup: copies the live AdGuardHome.yaml out of the
# container, checks it, checksums it and keeps the newest MAX_BACKUPS.
#
# Only the config volume is backed up. The work volume holds query logs and
# statistics, which are not worth keeping. The file contains the admin password
# hash, so it is written with mode 600.
#
# Newest = latest date in the filename (docker cp keeps the config mtime).
#
# Output:
#   adguard_YYYYMMDD.yaml
#   adguard_YYYYMMDD.yaml.sha256
#
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/home/vova/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-3}"
ADGUARD_CONTAINER="${ADGUARD_CONTAINER:-adguardhome-adguardhome-1}"
CONF_PATH="${CONF_PATH:-/opt/adguardhome/conf/AdGuardHome.yaml}"

DATE="$(date +%Y%m%d)"
OUT="$BACKUP_DIR/adguard_${DATE}.yaml"

mkdir -p "$BACKUP_DIR"
umask 077
TMP="$(mktemp "$BACKUP_DIR/.adguard.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# === COPY ===
echo "Copying $CONF_PATH from $ADGUARD_CONTAINER..."
docker cp "$ADGUARD_CONTAINER:$CONF_PATH" "$TMP"

# === VERIFY ===
if [[ ! -s "$TMP" ]]; then
    echo "ERROR: copied config is empty or missing!" >&2
    exit 1
fi
for key in "dns:" "filters:" "users:"; do
    if ! grep -q "^$key" "$TMP"; then
        echo "ERROR: top-level key '$key' not found in copied config!" >&2
        exit 1
    fi
done

# === SKIP IF UNCHANGED ===
NEW_SUM="$(sha256sum "$TMP" | awk '{print $1}')"
NEWEST="$(ls -1r "$BACKUP_DIR"/adguard_*.yaml 2>/dev/null | head -n 1 || true)"
if [[ -n "$NEWEST" ]]; then
    OLD_SUM="$(sha256sum "$NEWEST" | awk '{print $1}')"
    if [[ "$NEW_SUM" == "$OLD_SUM" ]]; then
        echo "No changes since $(basename "$NEWEST"). Backup skipped."
        exit 0
    fi
fi

# === WRITE + CHECKSUM ===
mv -f "$TMP" "$OUT"
chmod 600 "$OUT"
( cd "$BACKUP_DIR" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
chmod 600 "$OUT.sha256"

# === ROTATE (keep newest $MAX_BACKUPS) ===
mapfile -t STALE < <(ls -1r "$BACKUP_DIR"/adguard_*.yaml 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))
if (( ${#STALE[@]} > 0 )); then
    for old in "${STALE[@]}"; do
        echo "Pruning old backup: $(basename "$old")"
        rm -f -- "$old" "$old.sha256"
    done
fi

echo "Backup completed successfully!"
echo "Backup file:   $OUT"
echo "Checksum file: $OUT.sha256"
echo "Retention:     newest $MAX_BACKUPS kept in $BACKUP_DIR"
