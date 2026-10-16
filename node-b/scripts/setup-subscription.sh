#!/usr/bin/env bash
# ==============================================================================
# Node B Subscription Setup (Executed on Server B)
# Connects to Remote Node A across Network via Static IP
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
DB_HOST="${POSTGRES_HOST:-127.0.0.1}"
DB_PORT="${HOST_PORT:-5432}"

REMOTE_IP="${REMOTE_STATIC_IP:-${REMOTE_HOST}}"
REMOTE_PORT="${REMOTE_PORT:-5432}"
REMOTE_USER="${REMOTE_REPLICATION_USER:-replicator}"
REMOTE_PASSWORD="${REMOTE_REPLICATION_PASSWORD:-replicator_secure_pw_123}"
REMOTE_PUB="${REMOTE_PUBLICATION_NAME:-pub_node_a}"
SUB_NAME="${SUBSCRIPTION_NAME:-sub_node_a_to_b}"
SSL_MODE="${REPLICATION_SSL_MODE:-prefer}"

echo "=== [Node B] Establishing Logical Subscription to Remote Node A ==="
echo "Local Node:   ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "Remote Node:  ${REMOTE_IP}:${REMOTE_PORT}/${REMOTE_DB:-appdb}"
echo "SSL Mode:     ${SSL_MODE}"

export PGPASSWORD="${POSTGRES_PASSWORD:-postgres_master_pw}"

# 1. Verify remote node connectivity
echo -n "Checking network reachability to Remote Node A (${REMOTE_IP}:${REMOTE_PORT})..."
if ! pg_isready -h "${REMOTE_IP}" -p "${REMOTE_PORT}" -U "${REMOTE_USER}" -d "${REMOTE_DB:-appdb}" -q; then
    echo -e "\n[ERROR] Cannot connect to Remote Node A at ${REMOTE_IP}:${REMOTE_PORT}."
    echo "Please ensure:"
    echo "  1. Server A is running and port ${REMOTE_PORT} is open in the firewall/security group."
    echo "  2. Server A pg_hba.conf permits connections from this IP (${LOCAL_STATIC_IP:-local})."
    exit 1
fi
echo " [REACHABLE]"

# 2. Create publication on local Node B if not present
echo "Ensuring local publication ${PUBLICATION_NAME:-pub_node_b} exists..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '${PUBLICATION_NAME:-pub_node_b}') THEN
            CREATE PUBLICATION ${PUBLICATION_NAME:-pub_node_b} FOR ALL TABLES;
        END IF;
    END \$\$;
"

# 3. Create Subscription to Remote Node A with origin = 'none'
echo "Creating subscription '${SUB_NAME}'..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = '${SUB_NAME}') THEN
            CREATE SUBSCRIPTION ${SUB_NAME}
                CONNECTION 'host=${REMOTE_IP} port=${REMOTE_PORT} dbname=${REMOTE_DB:-appdb} user=${REMOTE_USER} password=${REMOTE_PASSWORD} sslmode=${SSL_MODE}'
                PUBLICATION ${REMOTE_PUB}
                WITH (copy_data = false, create_slot = true, origin = 'none');
            RAISE NOTICE 'Subscription ${SUB_NAME} created successfully.';
        ELSE
            RAISE NOTICE 'Subscription ${SUB_NAME} already exists.';
        END IF;
    END \$\$;
"

# 4. Configure postgres_fdw foreign table mapping to Remote Node A
echo "Configuring postgres_fdw foreign tables for reconciliation..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'remote_node_a') THEN
            CREATE SERVER remote_node_a
                FOREIGN DATA WRAPPER postgres_fdw
                OPTIONS (host '${REMOTE_IP}', port '${REMOTE_PORT}', dbname '${REMOTE_DB:-appdb}', sslmode '${SSL_MODE}');
            CREATE USER MAPPING FOR ${DB_USER}
                SERVER remote_node_a
                OPTIONS (user '${REMOTE_USER}', password '${REMOTE_PASSWORD}');
            IMPORT FOREIGN SCHEMA public LIMIT TO (users, orders, order_items)
                FROM SERVER remote_node_a INTO public;
            ALTER FOREIGN TABLE IF EXISTS users RENAME TO remote_users;
            ALTER FOREIGN TABLE IF EXISTS orders RENAME TO remote_orders;
            ALTER FOREIGN TABLE IF EXISTS order_items RENAME TO remote_order_items;
        END IF;
    END \$\$;
" 2>/dev/null || true

echo "✔ [Node B] Successfully configured subscription to Remote Node A!"
