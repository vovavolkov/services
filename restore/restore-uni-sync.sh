#!/bin/bash
#
# Restore the Syncthing "uni" folder from a uni-sync_*.tar.gz backup.
#
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"

UNI_DIR="${UNI_DIR:-/home/vova/Syncthing/uni}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-y] [--diff-only] <archive|datestamp>

  Restores $UNI_DIR from a uni-sync_*.tar.gz backup.
  Accepts a full path, a filename, or just the date (e.g. 20260628).

  --diff-only   unpack and show what differs, then stop without writing
  -y, --yes     skip the confirmation prompt (for unattended use)

  PAUSE THE FOLDER IN THE SYNCTHING UI FIRST. Otherwise Syncthing propagates
  the restored files to every peer the moment they land -- which is what you
  want if the loss was local, and very much not what you want if you are
  recovering from something that already synced everywhere.

$(list_archives uni-sync)
USAGE
}

DIFF_ONLY=0
FILTERED=()
for a in "$@"; do
    case "$a" in
        --diff-only) DIFF_ONLY=1 ;;
        *) FILTERED+=("$a") ;;
    esac
done
parse_flags ${FILTERED[@]+"${FILTERED[@]}"}
(( ${#ARGS[@]} == 1 )) || { usage; exit 1; }
need_cmd rsync

ARCHIVE="$(resolve_archive "${ARGS[0]}" uni-sync)"
verify_archive "$ARCHIVE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info "Unpacking $(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f1))"
tar -xzf "$ARCHIVE" -C "$WORK"
SRC="$WORK/uni"
[[ -d "$SRC" ]] || die "no uni/ directory inside $ARCHIVE"

info "Differences between the archive and the live folder (archive vs live):"
if [[ -d "$UNI_DIR" ]]; then
    # diff exits 1 whenever anything differs -- the normal case here -- so it
    # needs `|| true`. Run it once and reuse the output; a here-string avoids
    # piping into head, which would SIGPIPE diff on a large folder.
    DIFFS="$(diff -rq "$SRC" "$UNI_DIR" 2>&1 || true)"
    total="$(printf '%s' "$DIFFS" | grep -c . || true)"
    if [[ "${total:-0}" == "0" ]]; then
        info "No differences -- the live folder already matches this backup"
    else
        head -50 <<<"$DIFFS"
        (( total > 50 )) && info "... and $((total - 50)) more"
        info "$total differing entries in total"
    fi
else
    warn "$UNI_DIR does not exist -- this will be a fresh restore"
fi

if (( DIFF_ONLY )); then
    info "--diff-only given, stopping here. Nothing was written."
    exit 0
fi

confirm "This will overwrite files in $UNI_DIR with the contents of $(basename "$ARCHIVE"). Pause the folder in Syncthing first."

info "Restoring"
mkdir -p "$UNI_DIR"
rsync -a "$SRC/" "$UNI_DIR/"

cat <<DONE

Restore complete.

  Files present in $UNI_DIR but absent from the archive were left alone --
  rsync ran without --delete on purpose. Remove them by hand if you want an
  exact match to the backup.

  Resume the folder in the Syncthing UI when you are happy with the result.
DONE
