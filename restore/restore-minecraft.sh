#!/bin/bash
#
# Restore the Minecraft survival world.
#
# Backups are plain directories written by the mc-backup side-car, each holding
# a world/ directory. The legacy survival-world_*.tar.gz archives (made by the
# old host cron job) are also accepted.
#
# There is deliberately no restore-rsync-backup init container in the compose
# file: that helper only fires when /data is completely empty, and /data here
# always holds the mods mc-setup downloads, so it would never trigger.
#
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"

MC_DIR="${MC_DIR:-$SERVICES_DIR/mc-survival}"
MC_DATA="${MC_DATA:-/opt/docker/mc-survival}"
MC_BACKUPS="${MC_BACKUPS:-$BACKUP_DIR/mc-survival}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-y] <snapshot|latest|tarball>

  Restores the survival world, stopping the server while it swaps the files.
  The world being replaced is moved aside, not deleted, so a bad restore is
  recoverable until you remove it by hand.

    latest                          newest snapshot in $MC_BACKUPS
    mc-survival-YYYYMMDD-HHMMSS     a specific snapshot
    /path/to/survival-world_*.tar.gz  a legacy tar archive

  -y, --yes   skip the confirmation prompt (for unattended use)

Available snapshots in $MC_BACKUPS:
$(ls -1t "$MC_BACKUPS" 2>/dev/null | sed 's/^/  /' || echo '  (none)')
USAGE
}

parse_flags "$@"
(( ${#ARGS[@]} == 1 )) || { usage; exit 1; }
need_cmd docker; need_cmd rsync

SRC=""
case "${ARGS[0]}" in
    latest)
        # Resolve by mtime rather than trusting the LINK_LATEST symlink name.
        # sed rather than `head -1`: head exits after one line, which SIGPIPEs
        # sort, and `set -o pipefail` would turn that into a failed pipeline.
        SRC="$(find "$MC_BACKUPS" -mindepth 1 -maxdepth 1 -type d -name 'mc-survival-*' \
               -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed -n '1s/^[^ ]* //p')"
        [[ -n "$SRC" ]] || die "no snapshots found in $MC_BACKUPS"
        ;;
    *.tar.gz)
        SRC="${ARGS[0]}"
        [[ -f "$SRC" ]] || SRC="$BACKUP_DIR/${ARGS[0]}"
        [[ -f "$SRC" ]] || die "no such archive: ${ARGS[0]}"
        ;;
    *)
        SRC="${ARGS[0]}"
        [[ -d "$SRC" ]] || SRC="$MC_BACKUPS/${ARGS[0]}"
        [[ -d "$SRC" ]] || die "no such snapshot: ${ARGS[0]}"
        ;;
esac

info "Restoring from: $SRC"
[[ -d "$MC_DATA" ]] || die "no such directory: $MC_DATA"

confirm "This will stop the Minecraft server and replace $MC_DATA/world."

WORK=""
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -f "$SRC" ]]; then
    verify_archive "$SRC"
    WORK="$(mktemp -d)"
    info "Unpacking legacy archive"
    tar -xzf "$SRC" -C "$WORK"
    WORLD_SRC="$(find "$WORK" -mindepth 1 -maxdepth 3 -type d -name world -print -quit)"
else
    WORLD_SRC="$SRC/world"
fi
[[ -n "${WORLD_SRC:-}" && -d "$WORLD_SRC" ]] || die "no world/ directory found in $SRC"
[[ -f "$WORLD_SRC/level.dat" ]] || warn "$WORLD_SRC has no level.dat -- this may not be a valid world"

cd "$MC_DIR"
info "Stopping the stack"
docker compose down

STAMP="$(date +%Y%m%d-%H%M%S)"
ASIDE="$MC_DATA/world.before-restore-$STAMP"
if [[ -d "$MC_DATA/world" ]]; then
    info "Moving the current world aside: $(basename "$ASIDE")"
    mv "$MC_DATA/world" "$ASIDE"
fi

info "Copying the snapshot into place ($(du -sh "$WORLD_SRC" | cut -f1))"
rsync -a "$WORLD_SRC/" "$MC_DATA/world/"

info "Starting the stack (mc-setup and the worldgen merge re-run automatically)"
docker compose up -d

cat <<DONE

Restore complete.

  Watch it come up:   docker compose -f $MC_DIR/docker-compose.yaml logs -f mc
  Take a backup now:  docker compose -f $MC_DIR/docker-compose.yaml exec mc-backup backup now

  Once you have logged in and confirmed the world is correct, remove the old one:
    rm -rf $ASIDE
DONE
