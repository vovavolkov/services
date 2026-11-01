#!/bin/bash
#
# Shared helpers for the restore-* scripts. Sourced, not executed.
#
BACKUP_DIR="${BACKUP_DIR:-/home/vova/backups}"
SERVICES_DIR="${SERVICES_DIR:-/home/vova/services}"
ASSUME_YES="${ASSUME_YES:-0}"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# confirm <one-line description of what is about to be destroyed>
# Requires the operator to type "yes" in full. -y / --yes skips it.
confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    printf '\n!!! %s\n' "$1"
    printf '    This cannot be undone.\n'
    local reply
    read -r -p "    Type 'yes' to continue: " reply
    [[ "$reply" == "yes" ]] || die "aborted by operator"
}

# parse_flags "$@" -- sets ASSUME_YES and fills the ARGS array with the
# positional arguments. Each caller defines its own usage().
ARGS=()
parse_flags() {
    ARGS=()
    local a
    for a in "$@"; do
        case "$a" in
            -y|--yes)  ASSUME_YES=1 ;;
            -h|--help) usage; exit 0 ;;
            -*)        usage; die "unknown option: $a" ;;
            *)         ARGS+=("$a") ;;
        esac
    done
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# resolve_archive <name-or-path> <prefix>
# Accepts an absolute path, a bare filename, or just the date stamp, and
# echoes the resolved .tar.gz path.
resolve_archive() {
    local arg="$1" prefix="$2" c
    for c in "$arg" "$BACKUP_DIR/$arg" "$BACKUP_DIR/$arg.tar.gz" \
             "$BACKUP_DIR/${prefix}_$arg.tar.gz"; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    die "no archive found for '$arg' (looked in $BACKUP_DIR for ${prefix}_*.tar.gz)"
}

# verify_archive <path> -- checks the .sha256 if one exists, otherwise at least
# proves the archive is not truncated.
verify_archive() {
    local archive="$1"
    if [[ -f "$archive.sha256" ]]; then
        info "Verifying checksum"
        # Compare hashes directly instead of using `sha256sum -c`. Backups made
        # before 2026-09 recorded a relative path ("backups/fireflyiii_*.tar.gz")
        # inside the .sha256, so -c looks for a filename that is not there and
        # reports a failure that has nothing to do with the archive's integrity.
        local want got
        want="$(awk '{print $1; exit}' "$archive.sha256")"
        [[ ${#want} -eq 64 ]] || die "malformed checksum file: $archive.sha256"
        got="$(sha256sum "$archive" | awk '{print $1}')"
        [[ "$want" == "$got" ]] || die "checksum mismatch on $archive -- do not restore this
       expected $want
       got      $got"
        info "Checksum OK ($got)"
    else
        info "No .sha256 alongside this archive; checking it is at least readable"
        tar -tzf "$archive" >/dev/null || die "$archive is corrupt or truncated"
    fi
}

# list_archives <prefix> -- used by the usage messages
list_archives() {
    local prefix="$1"
    printf 'Available in %s:\n' "$BACKUP_DIR"
    ls -1t "$BACKUP_DIR/${prefix}"_*.tar.gz 2>/dev/null | sed 's/^/  /' || printf '  (none)\n'
}

# compose_project <dir> -- the real compose project name, which is not always
# the directory name (paperless-ngx/ runs as project "paperless").
compose_project() {
    ( cd "$1" && docker compose config --format json ) \
        | python3 -c 'import sys, json; print(json.load(sys.stdin)["name"])'
}

# wait_healthy <compose-dir> <service> [timeout-seconds]
wait_healthy() {
    local dir="$1" svc="$2" timeout="${3:-300}" waited=0 cid status
    info "Waiting for '$svc' to become healthy (timeout ${timeout}s)"
    while (( waited < timeout )); do
        cid="$( cd "$dir" && docker compose ps -q "$svc" 2>/dev/null )"
        if [[ -n "$cid" ]]; then
            status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
            [[ "$status" == "healthy" || "$status" == "running" ]] && { info "'$svc' is $status"; return 0; }
        fi
        sleep 5; waited=$((waited + 5))
    done
    die "'$svc' did not become healthy within ${timeout}s"
}
