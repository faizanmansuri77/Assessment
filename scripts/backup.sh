#!/usr/bin/env bash
#
# backup.sh - Creates a timestamped custom-format pg_dump backup of the
# local flightreservation database running via docker compose.
#
# Usage:
#   ./scripts/backup.sh
#
# Output:
#   backups/flightreservation_YYYYMMDD_HHMMSS.dump

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"

CONTAINER_NAME="${DB_CONTAINER_NAME:-flightreservation-db}"
DB_NAME="${DB_NAME:-flightreservation}"
DB_USER="${DB_USER:-app_user}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/flightreservation_${TIMESTAMP}.dump"

mkdir -p "$BACKUP_DIR"

# Make sure the DB container is actually up before we try to talk to it.
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: container '${CONTAINER_NAME}' is not running." >&2
    echo "Start it first with: docker compose up -d" >&2
    exit 1
fi

echo "Backing up database '${DB_NAME}' from container '${CONTAINER_NAME}'..."

# -F c = custom format: compressed, and restorable with pg_restore
# (including selective/parallel restore), which is why we use it here
# rather than a plain .sql text dump.
docker exec -t "$CONTAINER_NAME" \
    pg_dump -U "$DB_USER" -d "$DB_NAME" -F c \
    > "$BACKUP_FILE"

echo "Backup complete: $BACKUP_FILE"
echo "Size: $(du -h "$BACKUP_FILE" | cut -f1)"
