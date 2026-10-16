#!/usr/bin/env bash
# ==============================================================================
# Node B Disaster Recovery Restore Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -f "${PROJECT_ROOT}/node-b/.env" ]]; then
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/node-b/.env"
fi

DB_NAME="${POSTGRES_DB:-appdb}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_HOST="${POSTGRES_HOST:-127.0.0.1}"
DB_PORT="${HOST_PORT:-5433}"
DB_PASSWORD="${POSTGRES_PASSWORD:-postgres_master_pw}"
BACKUP_DIR="${SCRIPT_DIR}/backups"

BACKUP_FILE="${1:-}"

if [[ -z "${BACKUP_FILE}" ]]; then
    # Pick the latest backup automatically
    BACKUP_FILE=$(find "${BACKUP_DIR}" -name "node-b_backup_*.sql.gz" | sort -r | head -n 1 || true)
fi

if [[ -z "${BACKUP_FILE}" || ! -f "${BACKUP_FILE}" ]]; then
    echo "✘ Error: No valid backup file found to restore."
    echo "Usage: $0 [path/to/backup.sql.gz]"
    exit 1
fi

echo "=== [Node B] Starting Disaster Recovery Restore ==="
echo "Target DB: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "Archive:   ${BACKUP_FILE}"

# Verify Checksum if present
if [[ -f "${BACKUP_FILE}.sha256" ]]; then
    echo "Verifying SHA-256 Checksum..."
    if ! sha256sum -c "${BACKUP_FILE}.sha256"; then
        echo "✘ Checksum verification failed! Corrupted archive."
        exit 1
    fi
    echo "✔ Checksum verified successfully."
fi

export PGPASSWORD="${DB_PASSWORD}"

echo "Restoring database from compressed archive..."
gunzip -c "${BACKUP_FILE}" | psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres

echo "✔ Node B restore complete!"
