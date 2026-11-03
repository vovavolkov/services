#!/bin/bash

# === ARGUMENTS ===
SOURCE_PATH="$1"
CUSTOM_NAME="$2"

if [[ -z "$SOURCE_PATH" || -z "$CUSTOM_NAME" ]]; then
    echo "Usage: $0 <source_path> <custom_name>"
    exit 1
fi

# === SETUP ===
DATE=$(date +%Y%m%d)
ORIGINAL_USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
BACKUP_DIR="$ORIGINAL_USER_HOME/backups"
CHECKSUM_FILE="$BACKUP_DIR/${CUSTOM_NAME}.checksum"
BACKUP_FILE="${CUSTOM_NAME}_${DATE}.tar.gz"
MAX_BACKUPS=2

mkdir -p "$BACKUP_DIR"

echo "Creating backup for $SOURCE_PATH as $CUSTOM_NAME."

# === FUNCTION: calculate checksum of folder ===
calculate_checksum() {
    find "$SOURCE_PATH" -type f -exec md5sum {} \; | sort | md5sum | awk '{ print $1 }'
}

# === CHECK FOR CHANGES ===
CURRENT_CHECKSUM=$(calculate_checksum)
PREVIOUS_CHECKSUM=$(cat "$CHECKSUM_FILE" 2>/dev/null)

if [[ "$CURRENT_CHECKSUM" == "$PREVIOUS_CHECKSUM" ]]; then
    echo "No changes detected in '$SOURCE_PATH'. Backup skipped."
    exit 0
fi

# === CREATE BACKUP ===
tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$(dirname "$SOURCE_PATH")" "$(basename "$SOURCE_PATH")"
echo "Backup created: $BACKUP_DIR/$BACKUP_FILE"

# === SAVE NEW CHECKSUM ===
echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"

# === ROTATE OLD BACKUPS (keep only newest $MAX_BACKUPS) ===
ls -1t "$BACKUP_DIR/${CUSTOM_NAME}_"*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --

echo "Old backups rotated. Only the latest $MAX_BACKUPS are kept."

