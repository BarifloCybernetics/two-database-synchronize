#!/usr/bin/env bash
# ==============================================================================
# Node B Health Check Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source .env if exists
if [[ -f "${NODE_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${NODE_DIR}/.env"
fi

DB_NAME="${POSTGRES_DB:-appdb}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_HOST="${POSTGRES_HOST:-localhost}"
REMOTE_HOST="${REMOTE_STATIC_IP:-${REMOTE_HOST:-node-a}}"
REMOTE_PORT="${REMOTE_PORT:-5432}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== [Node B] Health Check: $(date -u +"%Y-%m-%d %H:%M:%SZ") ===${NC}"

STATUS=0

# 1. Local Database Connectivity
if pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q; then
    echo -e " [✔] Local PostgreSQL (${DB_HOST}:${DB_PORT}/${DB_NAME}): ${GREEN}ONLINE${NC}"
else
    echo -e " [✘] Local PostgreSQL (${DB_HOST}:${DB_PORT}/${DB_NAME}): ${RED}UNREACHABLE${NC}"
    exit 2
fi

# 2. Check WAL & Logical Replication Settings
WAL_LEVEL=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SHOW wal_level;" 2>/dev/null || echo "error")
TRACK_COMMIT=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SHOW track_commit_timestamp;" 2>/dev/null || echo "error")

if [[ "${WAL_LEVEL}" == "logical" ]]; then
    echo -e " [✔] WAL Level: ${GREEN}${WAL_LEVEL}${NC}"
else
    echo -e " [✘] WAL Level: ${RED}${WAL_LEVEL} (Expected: logical)${NC}"
    STATUS=1
fi

if [[ "${TRACK_COMMIT}" == "on" ]]; then
    echo -e " [✔] Track Commit Timestamp: ${GREEN}${TRACK_COMMIT}${NC}"
else
    echo -e " [!] Track Commit Timestamp: ${YELLOW}${TRACK_COMMIT} (Recommended: on)${NC}"
fi

# 3. Check Subscription Status
SUB_STATUS=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
    SELECT coalesce(string_agg(subname || ':' || CASE WHEN pid IS NOT NULL THEN 'ACTIVE' ELSE 'INACTIVE' END, ', '), 'NONE')
    FROM pg_stat_subscription;
" 2>/dev/null || echo "error")

if [[ "${SUB_STATUS}" == *"ACTIVE"* ]]; then
    echo -e " [✔] Subscriptions: ${GREEN}${SUB_STATUS}${NC}"
elif [[ "${SUB_STATUS}" == "NONE" ]]; then
    echo -e " [!] Subscriptions: ${YELLOW}NO SUBSCRIPTIONS REGISTERED${NC}"
else
    echo -e " [✘] Subscriptions: ${RED}${SUB_STATUS}${NC}"
    STATUS=1
fi

# 4. Check Replication Slots
SLOTS=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
    SELECT coalesce(string_agg(slot_name || ':' || CASE WHEN active THEN 'ACTIVE' ELSE 'INACTIVE' END, ', '), 'NONE')
    FROM pg_replication_slots;
" 2>/dev/null || echo "error")
echo -e " [ℹ] Replication Slots: ${BLUE}${SLOTS}${NC}"

# 5. Remote Host Connectivity
if pg_isready -h "${REMOTE_HOST}" -p "${REMOTE_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t 2 -q 2>/dev/null; then
    echo -e " [✔] Remote Node (${REMOTE_HOST}:${REMOTE_PORT}): ${GREEN}REACHABLE${NC}"
else
    echo -e " [!] Remote Node (${REMOTE_HOST}:${REMOTE_PORT}): ${YELLOW}CANNOT REACH (Normal during startup/maintenance)${NC}"
fi

echo -e "${BLUE}=== Health Check Completed (Exit code: ${STATUS}) ===${NC}\n"
exit ${STATUS}
