#!/usr/bin/env bash
#
# restore.sh - Restores a pg_dump backup (created by backup.sh) into a
# FRESH local database (dropped and recreated), so restore is always
# tested against a clean target rather than layered on top of existing data.
#
# Usage:
#   ./scripts/restore.sh                              # restores latest backup
#   ./scripts/restore.sh backups/flightreservation_20260708_120000.dump

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"

CONTAINER_NAME="${DB_CONTAINER_NAME:-flightreservation-db}"
DB_USER="${DB_USER:-app_user}"
RESTORE_DB_NAME="${RESTORE_DB_NAME:-flightreservation_restore}"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: container '${CONTAINER_NAME}' is not running." >&2
    echo "Start it first with: docker compose up -d" >&2
    exit 1
fi

# Resolve which backup file to restore.
if [[ $# -ge 1 ]]; then
    BACKUP_FILE="$1"
else
    BACKUP_FILE="$(ls -t "$BACKUP_DIR"/flightreservation_*.dump 2>/dev/null | head -n1 || true)"
    if [[ -z "$BACKUP_FILE" ]]; then
        echo "Error: no backup files found in $BACKUP_DIR and none specified." >&2
        echo "Usage: ./scripts/restore.sh [path-to-backup.dump]" >&2
        exit 1
    fi
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Error: backup file not found: $BACKUP_FILE" >&2
    exit 1
fi

echo "Restoring '$BACKUP_FILE' into fresh database '${RESTORE_DB_NAME}'..."

# Recreate the target database from scratch so restore is proven against a
# genuinely clean database, not merged on top of whatever was already there.
docker exec -t "$CONTAINER_NAME" \
    psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${RESTORE_DB_NAME};" \
    -c "CREATE DATABASE ${RESTORE_DB_NAME};"

# Stream the dump file into the container and restore it.
docker exec -i "$CONTAINER_NAME" \
    pg_restore -U "$DB_USER" -d "$RESTORE_DB_NAME" --no-owner --clean --if-exists \
    < "$BACKUP_FILE"

echo "Restore complete into database '${RESTORE_DB_NAME}'."
echo ""
echo "Verification:"

BOOKINGS_COUNT=$(docker exec -t "$CONTAINER_NAME" \
    psql -U "$DB_USER" -d "$RESTORE_DB_NAME" -t -A -c "SELECT count(*) FROM hotel_bookings;" | tr -d '[:space:]')
EVENTS_COUNT=$(docker exec -t "$CONTAINER_NAME" \
    psql -U "$DB_USER" -d "$RESTORE_DB_NAME" -t -A -c "SELECT count(*) FROM booking_events;" | tr -d '[:space:]')

echo "  hotel_bookings rows: $BOOKINGS_COUNT"
echo "  booking_events rows: $EVENTS_COUNT"

if [[ "$BOOKINGS_COUNT" -gt 0 ]]; then
    echo ""
    echo "Restore verified: hotel_bookings is populated in '${RESTORE_DB_NAME}'."
else
    echo ""
    echo "Warning: hotel_bookings is empty after restore - check the backup file." >&2
    exit 1
fi
