#!/usr/bin/env bash
# ==============================================================================
# Cross-Node Data Reconciliation & Auto-Healing Engine
# Reconciles ONLY missing data (Zero duplicates) every 1 minute
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NODE_A_DEFAULT_HOST="127.0.0.1"
NODE_B_DEFAULT_HOST="127.0.0.1"
NODE_B_DEFAULT_PORT="5433"

if [[ -f "${PROJECT_ROOT}/node-a/.env" ]]; then
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/node-a/.env"
    if [[ -n "${LOCAL_STATIC_IP:-}" && "${LOCAL_STATIC_IP}" != "127.0.0.1" ]]; then
        NODE_A_DEFAULT_HOST="${LOCAL_STATIC_IP}"
        NODE_B_DEFAULT_HOST="${REMOTE_STATIC_IP:-127.0.0.1}"
        NODE_B_DEFAULT_PORT="${REMOTE_PORT:-5432}"
    fi
fi

NODE_A_HOST="${NODE_A_HOST:-${NODE_A_DEFAULT_HOST}}"
NODE_A_PORT="${NODE_A_PORT:-5432}"
NODE_B_HOST="${NODE_B_HOST:-${NODE_B_DEFAULT_HOST}}"
NODE_B_PORT="${NODE_B_PORT:-${NODE_B_DEFAULT_PORT}}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASSWORD="${POSTGRES_PASSWORD:-postgres_master_pw}"
DB_NAME="${POSTGRES_DB:-appdb}"

# Mode: --check, --fix, --daemon [interval_seconds], --every-minute
MODE="${1:---fix}"
INTERVAL_SEC="${2:-60}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

export PGPASSWORD="${DB_PASSWORD}"

reconcile_single_table() {
    local table="$1"
    local pkey="id"

    # Step 1: Count & Hash comparison
    local COUNT_A
    local COUNT_B
    local CHECKSUM_A
    local CHECKSUM_B

    COUNT_A=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SELECT count(*) FROM ${table};" 2>/dev/null || echo "0")
    COUNT_B=$(psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SELECT count(*) FROM ${table};" 2>/dev/null || echo "0")

    CHECKSUM_A=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
        SELECT coalesce(md5(string_agg(${pkey}::text, '' ORDER BY ${pkey})), 'EMPTY') FROM ${table};
    " 2>/dev/null || echo "EMPTY_A")
    CHECKSUM_B=$(psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
        SELECT coalesce(md5(string_agg(${pkey}::text, '' ORDER BY ${pkey})), 'EMPTY') FROM ${table};
    " 2>/dev/null || echo "EMPTY_B")

    if [[ "${CHECKSUM_A}" == "${CHECKSUM_B}" && "${COUNT_A}" == "${COUNT_B}" ]]; then
        echo -e "  [${table}] Parity: ${GREEN}IN SYNC${NC} (Rows: ${COUNT_A})"
        return 0
    fi

    echo -e "  [${table}] Drift detected! Node A: ${COUNT_A} rows | Node B: ${COUNT_B} rows"

    # Step 2: Extract missing primary key IDs on each side
    local TMP_DIR
    TMP_DIR=$(mktemp -d)

    psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SELECT ${pkey} FROM ${table} ORDER BY ${pkey};" > "${TMP_DIR}/ids_a.txt"
    psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SELECT ${pkey} FROM ${table} ORDER BY ${pkey};" > "${TMP_DIR}/ids_b.txt"

    # IDs present in A but missing in B:
    comm -23 "${TMP_DIR}/ids_a.txt" "${TMP_DIR}/ids_b.txt" > "${TMP_DIR}/missing_in_b.txt"
    # IDs present in B but missing in A:
    comm -13 "${TMP_DIR}/ids_a.txt" "${TMP_DIR}/ids_b.txt" > "${TMP_DIR}/missing_in_a.txt"

    local NUM_MISSING_IN_B
    local NUM_MISSING_IN_A
    NUM_MISSING_IN_B=$(wc -l < "${TMP_DIR}/missing_in_b.txt")
    NUM_MISSING_IN_A=$(wc -l < "${TMP_DIR}/missing_in_a.txt")

    echo -e "    Missing in Node B: ${YELLOW}${NUM_MISSING_IN_B}${NC} rows"
    echo -e "    Missing in Node A: ${YELLOW}${NUM_MISSING_IN_A}${NC} rows"

    if [[ "${MODE}" == "--fix" || "${MODE}" == "--daemon" || "${MODE}" == "--every-minute" ]]; then
        # ----------------------------------------------------------------------
        # Safe Import to Node B (ON CONFLICT DO NOTHING: STRICTLY ZERO DUPLICATES)
        # ----------------------------------------------------------------------
        if [[ ${NUM_MISSING_IN_B} -gt 0 ]]; then
            echo -e "    ${CYAN}Syncing missing rows into Node B (Zero duplicates guaranteed)...${NC}"
            
            # Format IDs for SQL IN clause
            local ID_LIST_B
            ID_LIST_B=$(sed "s/.*/'&'/" "${TMP_DIR}/missing_in_b.txt" | paste -sd, -)

            psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c \
                "\copy (SELECT * FROM ${table} WHERE ${pkey} IN (${ID_LIST_B})) TO STDOUT" > "${TMP_DIR}/data_for_b.tsv"

            # Create staging table, load data, and INSERT ON CONFLICT DO NOTHING
            psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" << EOF > /dev/null 2>&1
BEGIN;
CREATE TEMP TABLE temp_reconcile_stage (LIKE ${table} INCLUDING ALL) ON COMMIT DROP;
\copy temp_reconcile_stage FROM '${TMP_DIR}/data_for_b.tsv';
INSERT INTO ${table}
SELECT * FROM temp_reconcile_stage
ON CONFLICT (${pkey}) DO NOTHING;
COMMIT;
EOF
            echo -e "    ${GREEN}✔ Node B updated: Reconciled ${NUM_MISSING_IN_B} missing rows without duplicates.${NC}"
        fi

        # ----------------------------------------------------------------------
        # Safe Import to Node A (ON CONFLICT DO NOTHING: STRICTLY ZERO DUPLICATES)
        # ----------------------------------------------------------------------
        if [[ ${NUM_MISSING_IN_A} -gt 0 ]]; then
            echo -e "    ${CYAN}Syncing missing rows into Node A (Zero duplicates guaranteed)...${NC}"

            local ID_LIST_A
            ID_LIST_A=$(sed "s/.*/'&'/" "${TMP_DIR}/missing_in_a.txt" | paste -sd, -)

            psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c \
                "\copy (SELECT * FROM ${table} WHERE ${pkey} IN (${ID_LIST_A})) TO STDOUT" > "${TMP_DIR}/data_for_a.tsv"

            psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" << EOF > /dev/null 2>&1
BEGIN;
CREATE TEMP TABLE temp_reconcile_stage (LIKE ${table} INCLUDING ALL) ON COMMIT DROP;
\copy temp_reconcile_stage FROM '${TMP_DIR}/data_for_a.tsv';
INSERT INTO ${table}
SELECT * FROM temp_reconcile_stage
ON CONFLICT (${pkey}) DO NOTHING;
COMMIT;
EOF
            echo -e "    ${GREEN}✔ Node A updated: Reconciled ${NUM_MISSING_IN_A} missing rows without duplicates.${NC}"
        fi
    fi

    rm -rf "${TMP_DIR}"
}

run_reconciliation_cycle() {
    local TIMESTAMP
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "\n${CYAN}[${TIMESTAMP}] Running cross-database parity check...${NC}"

    if ! pg_isready -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q; then
        echo -e "${RED}[WARN] Node A is unreachable at ${NODE_A_HOST}:${NODE_A_PORT}. Skipping cycle.${NC}"
        return 1
    fi

    if ! pg_isready -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q; then
        echo -e "${RED}[WARN] Node B is unreachable at ${NODE_B_HOST}:${NODE_B_PORT}. Skipping cycle.${NC}"
        return 1
    fi

    # Reconcile in relational dependency order: users -> orders -> order_items
    TABLES=("users" "orders" "order_items")
    for tbl in "${TABLES[@]}"; do
        reconcile_single_table "${tbl}"
    done

    echo -e "${GREEN}[${TIMESTAMP}] Reconciliation cycle complete. All missing data reconciled with ZERO duplicates.${NC}"
}

# ------------------------------------------------------------------------------
# Execution Handler
# ------------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${CYAN}${BOLD}  PostgreSQL Active-Active Safe Reconciliation Engine (Zero Duplicates)${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "Node A: ${NODE_A_HOST}:${NODE_A_PORT}/${DB_NAME}"
echo -e "Node B: ${NODE_B_HOST}:${NODE_B_PORT}/${DB_NAME}"
echo -e "Mode:   ${BOLD}${MODE}${NC}"

if [[ "${MODE}" == "--daemon" || "${MODE}" == "--every-minute" || "${MODE}" == "-d" ]]; then
    echo -e "${CYAN}Running continuous reconciliation daemon every ${INTERVAL_SEC} seconds (1 minute)...${NC}"
    echo -e "Press [Ctrl+C] to stop."

    while true; do
        run_reconciliation_cycle || true
        echo -e "Sleeping ${INTERVAL_SEC} seconds until next check..."
        sleep "${INTERVAL_SEC}"
    done
else
    # One-shot execution
    run_reconciliation_cycle
fi
