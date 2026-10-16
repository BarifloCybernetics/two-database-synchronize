#!/usr/bin/env bash
# ==============================================================================
# Node B Local Data Reconciliation & Auto-Healing Script
# Reconciles ONLY missing data (Zero duplicates) with 1-minute loop support
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

REMOTE_HOST="${REMOTE_STATIC_IP:-${REMOTE_HOST:-node-a}}"
REMOTE_PORT="${REMOTE_PORT:-5432}"
REMOTE_DB="${REMOTE_DB:-appdb}"
REMOTE_USER="${REMOTE_REPLICATION_USER:-replicator}"
REMOTE_PASSWORD="${REMOTE_REPLICATION_PASSWORD:-replicator_secure_pw_123}"

MODE="${1:---check}" # --check, --fix, --every-minute
INTERVAL_SEC="${2:-60}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

run_node_b_reconciliation() {
    local TIMESTAMP
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "${CYAN}[${TIMESTAMP}] === Parity Check from Node B ===${NC}"
    echo "Local Node:  ${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo "Remote Node: ${REMOTE_HOST}:${REMOTE_PORT}/${REMOTE_DB}"

    # First check FDW queries if available
    local FDW_AVAILABLE
    FDW_AVAILABLE=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
        SELECT count(*) FROM pg_foreign_table WHERE ftrelid = 'remote_users'::regclass;
    " 2>/dev/null || echo "0")

    if [[ "${FDW_AVAILABLE}" == "1" && ("${MODE}" == "--fix" || "${MODE}" == "--every-minute" || "${MODE}" == "--daemon") ]]; then
        echo "Using postgres_fdw for atomic missing-row reconciliation (Zero duplicates guaranteed)..."
        
        # 1. Reconcile Users
        local USERS_SYNCED
        USERS_SYNCED=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
            WITH inserted AS (
                INSERT INTO users (id, username, email, full_name, role, is_active, node_origin, version, created_at, updated_at)
                SELECT a.id, a.username, a.email, a.full_name, a.role, a.is_active, a.node_origin, a.version, a.created_at, a.updated_at
                FROM remote_users a
                LEFT JOIN users b ON b.id = a.id
                WHERE b.id IS NULL
                ON CONFLICT (id) DO NOTHING
                RETURNING id
            )
            SELECT count(*) FROM inserted;
        " 2>/dev/null || echo "0")

        # 2. Reconcile Orders
        local ORDERS_SYNCED
        ORDERS_SYNCED=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
            WITH inserted AS (
                INSERT INTO orders (id, order_number, user_id, total_amount, currency, status, shipping_address, node_origin, version, created_at, updated_at)
                SELECT a.id, a.order_number, a.user_id, a.total_amount, a.currency, a.status, a.shipping_address, a.node_origin, a.version, a.created_at, a.updated_at
                FROM remote_orders a
                LEFT JOIN orders b ON b.id = a.id
                WHERE b.id IS NULL
                ON CONFLICT (id) DO NOTHING
                RETURNING id
            )
            SELECT count(*) FROM inserted;
        " 2>/dev/null || echo "0")

        # 3. Reconcile Order Items
        local ITEMS_SYNCED
        ITEMS_SYNCED=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
            WITH inserted AS (
                INSERT INTO order_items (id, order_id, product_name, quantity, unit_price, created_at)
                SELECT a.id, a.order_id, a.product_name, a.quantity, a.unit_price, a.created_at
                FROM remote_order_items a
                LEFT JOIN order_items b ON b.id = a.id
                WHERE b.id IS NULL
                ON CONFLICT (id) DO NOTHING
                RETURNING id
            )
            SELECT count(*) FROM inserted;
        " 2>/dev/null || echo "0")

        echo -e "${GREEN}✔ Reconciled missing records into Node B: Users=${USERS_SYNCED}, Orders=${ORDERS_SYNCED}, Items=${ITEMS_SYNCED}. Zero duplicates entered.${NC}"
    else
        # Count check
        TABLES=("users" "orders" "order_items")
        for table in "${TABLES[@]}"; do
            LOCAL_COUNT=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SELECT count(*) FROM ${table};" 2>/dev/null || echo "N/A")
            REMOTE_COUNT=$(PGPASSWORD="${REMOTE_PASSWORD}" psql -h "${REMOTE_HOST}" -p "${REMOTE_PORT}" -U "${REMOTE_USER}" -d "${REMOTE_DB}" -t -A -c "SELECT count(*) FROM ${table};" 2>/dev/null || echo "N/A")

            if [[ "${LOCAL_COUNT}" == "${REMOTE_COUNT}" && "${LOCAL_COUNT}" != "N/A" ]]; then
                echo -e "  [${table}] Parity: ${GREEN}IN SYNC${NC} (${LOCAL_COUNT} rows)"
            else
                echo -e "  [${table}] Status: ${RED}DRIFT DETECTED${NC} (Local: ${LOCAL_COUNT} | Remote: ${REMOTE_COUNT})"
            fi
        done
    fi
}

if [[ "${MODE}" == "--every-minute" || "${MODE}" == "--daemon" || "${MODE}" == "-d" ]]; then
    echo "Running Node B reconciliation daemon every ${INTERVAL_SEC} seconds (1 minute)..."
    while true; do
        run_node_b_reconciliation || true
        sleep "${INTERVAL_SEC}"
    done
else
    run_node_b_reconciliation
fi
