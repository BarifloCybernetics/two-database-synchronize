#!/usr/bin/env bash
# ==============================================================================
# Node A Replication Status Monitor
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${NODE_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${NODE_DIR}/.env"
fi

DB_NAME="${POSTGRES_DB:-appdb}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_HOST="${POSTGRES_HOST:-localhost}"
DB_PORT="${POSTGRES_PORT:-5432}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}================================================================${NC}"
echo -e "${CYAN}${BOLD}         NODE A - LOGICAL REPLICATION DIAGNOSTICS               ${NC}"
echo -e "${CYAN}${BOLD}================================================================${NC}"

# Current WAL position
CURRENT_WAL=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "N/A")
echo -e "Current WAL LSN: ${BOLD}${CURRENT_WAL}${NC}\n"

# 1. Outgoing Replication (Pub -> Sub)
echo -e "${GREEN}${BOLD}[1] Outgoing Replication (pg_stat_replication):${NC}"
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    SELECT
        pid,
        usename,
        application_name,
        client_addr,
        state,
        sent_lsn,
        write_lsn,
        flush_lsn,
        replay_lsn,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
        sync_state
    FROM pg_stat_replication;
" || true

# 2. Incoming Subscriptions (Sub <- Pub)
echo -e "\n${GREEN}${BOLD}[2] Incoming Subscriptions (pg_stat_subscription):${NC}"
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    SELECT
        subid,
        subname,
        pid,
        received_lsn,
        last_msg_send_time,
        last_msg_receipt_time,
        latest_end_lsn,
        latest_end_time
    FROM pg_stat_subscription;
" || true

# 3. Replication Slots
echo -e "\n${GREEN}${BOLD}[3] Local Replication Slots (pg_replication_slots):${NC}"
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    SELECT
        slot_name,
        plugin,
        slot_type,
        active,
        wal_status,
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retain_lag_bytes
    FROM pg_replication_slots;
" || true

# 4. Publications List
echo -e "\n${GREEN}${BOLD}[4] Publications Defined (pg_publication):${NC}"
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate
    FROM pg_publication;
" || true

echo -e "${CYAN}================================================================${NC}\n"
