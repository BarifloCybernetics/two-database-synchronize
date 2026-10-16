#!/usr/bin/env bash
# ==============================================================================
# Node B Automated Backup Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source .env if exists
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
RETENTION_DAYS=7

mkdir -p "${BACKUP_DIR}"

TIMESTAMP=$(date -u +"%Y%m%d_%H%M%SZ")
BACKUP_FILE="${BACKUP_DIR}/node-b_backup_${TIMESTAMP}.sql.gz"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"

echo "=== [Node B] Starting Automated Backup ==="
echo "Target: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "Output: ${BACKUP_FILE}"

export PGPASSWORD="${DB_PASSWORD}"

# Execute pg_dump with custom directory or compressed format
if pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" --clean --if-exists --create | gzip > "${BACKUP_FILE}"; then
    sha256sum "${BACKUP_FILE}" > "${CHECKSUM_FILE}"
    FILE_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    echo "✔ Backup successful! Size: ${FILE_SIZE}"
    echo "✔ SHA-256 Checksum generated: $(cat "${CHECKSUM_FILE}")"
else
    echo "✘ Backup failed!"
    exit 1
fi

# Retention policy: remove backups older than RETENTION_DAYS
echo "Applying retention policy (retaining last ${RETENTION_DAYS} days)..."
find "${BACKUP_DIR}" -name "node-b_backup_*.sql.gz*" -mtime "+${RETENTION_DAYS}" -exec rm -f {} +

echo "=== [Node B] Backup Procedure Complete ==="
