#!/usr/bin/env bash
# ==============================================================================
# Bidirectional Logical Replication & FDW Setup Orchestrator
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Network coordinates (defaults to container names, or uses static IPs if defined)
NODE_A_ENV="${PROJECT_ROOT}/node-a/.env"
NODE_B_ENV="${PROJECT_ROOT}/node-b/.env"

NODE_A_DEFAULT_HOST="node-a"
NODE_B_DEFAULT_HOST="node-b"

if [[ -f "${NODE_A_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${NODE_A_ENV}"
    NODE_A_DEFAULT_HOST="${LOCAL_STATIC_IP:-node-a}"
fi
if [[ -f "${NODE_B_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${NODE_B_ENV}"
    NODE_B_DEFAULT_HOST="${LOCAL_STATIC_IP:-node-b}"
fi

NODE_A_HOST="${NODE_A_HOST:-${NODE_A_DEFAULT_HOST}}"
NODE_A_PORT="${NODE_A_PORT:-5432}"
NODE_B_HOST="${NODE_B_HOST:-${NODE_B_DEFAULT_HOST}}"
NODE_B_PORT="${NODE_B_PORT:-5432}"

DB_USER="${POSTGRES_USER:-postgres}"
DB_PASSWORD="${POSTGRES_PASSWORD:-postgres_master_pw}"
DB_NAME="${POSTGRES_DB:-appdb}"
REPL_USER="${REPLICATION_USER:-replicator}"
REPL_PASSWORD="${REPLICATION_PASSWORD:-replicator_secure_pw_123}"
SSL_MODE="${REPLICATION_SSL_MODE:-prefer}"

export PGPASSWORD="${DB_PASSWORD}"

echo "=== Initializing Active-Active Logical Replication Cluster ==="

# 1. Wait for Node A
echo -n "Waiting for ${NODE_A_HOST}:${NODE_A_PORT} to accept connections..."
until pg_isready -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q; do
    echo -n "."
    sleep 1
done
echo " [ONLINE]"

# 2. Wait for Node B
echo -n "Waiting for ${NODE_B_HOST}:${NODE_B_PORT} to accept connections..."
until pg_isready -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q; do
    echo -n "."
    sleep 1
done
echo " [ONLINE]"

# 3. Ensure Publications Exist on Both Nodes
echo "Ensuring publications on both nodes..."
psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'pub_node_a') THEN
            CREATE PUBLICATION pub_node_a FOR ALL TABLES;
        END IF;
    END \$\$;
"

psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'pub_node_b') THEN
            CREATE PUBLICATION pub_node_b FOR ALL TABLES;
        END IF;
    END \$\$;
"

# 4. Create Subscription on Node A (subscribing to Node B)
# Note: 'origin = none' is the key parameter in PostgreSQL 16+ that prevents infinite replication loops!
echo "Setting up subscription on Node A (sub_node_b_to_a)..."
psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'sub_node_b_to_a') THEN
            CREATE SUBSCRIPTION sub_node_b_to_a
                CONNECTION 'host=${NODE_B_HOST} port=${NODE_B_PORT} dbname=${DB_NAME} user=${REPL_USER} password=${REPL_PASSWORD} sslmode=${SSL_MODE}'
                PUBLICATION pub_node_b
                WITH (copy_data = false, create_slot = true, origin = 'none');
            RAISE NOTICE 'Subscription sub_node_b_to_a created with origin = none';
        ELSE
            RAISE NOTICE 'Subscription sub_node_b_to_a already exists';
        END IF;
    END \$\$;
"

# 5. Create Subscription on Node B (subscribing to Node A)
echo "Setting up subscription on Node B (sub_node_a_to_b)..."
psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'sub_node_a_to_b') THEN
            CREATE SUBSCRIPTION sub_node_a_to_b
                CONNECTION 'host=${NODE_A_HOST} port=${NODE_A_PORT} dbname=${DB_NAME} user=${REPL_USER} password=${REPL_PASSWORD} sslmode=${SSL_MODE}'
                PUBLICATION pub_node_a
                WITH (copy_data = false, create_slot = true, origin = 'none');
            RAISE NOTICE 'Subscription sub_node_a_to_b created with origin = none';
        ELSE
            RAISE NOTICE 'Subscription sub_node_a_to_b already exists';
        END IF;
    END \$\$;
"

# 6. Setup Postgres FDW for Direct Cross-Node Queries and Reconciliation
echo "Configuring postgres_fdw mappings between Node A and Node B..."

# Node A -> Remote Node B
psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'remote_node_b') THEN
            CREATE SERVER remote_node_b
                FOREIGN DATA WRAPPER postgres_fdw
                OPTIONS (host '${NODE_B_HOST}', port '${NODE_B_PORT}', dbname '${DB_NAME}');
            CREATE USER MAPPING FOR ${DB_USER}
                SERVER remote_node_b
                OPTIONS (user '${REPL_USER}', password '${REPL_PASSWORD}');
            IMPORT FOREIGN SCHEMA public LIMIT TO (users, orders, order_items)
                FROM SERVER remote_node_b INTO public;
            ALTER FOREIGN TABLE IF EXISTS users RENAME TO remote_users;
            ALTER FOREIGN TABLE IF EXISTS orders RENAME TO remote_orders;
            ALTER FOREIGN TABLE IF EXISTS order_items RENAME TO remote_order_items;
        END IF;
    END \$\$;
" 2>/dev/null || true

# Node B -> Remote Node A
psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'remote_node_a') THEN
            CREATE SERVER remote_node_a
                FOREIGN DATA WRAPPER postgres_fdw
                OPTIONS (host '${NODE_A_HOST}', port '${NODE_A_PORT}', dbname '${DB_NAME}');
            CREATE USER MAPPING FOR ${DB_USER}
                SERVER remote_node_a
                OPTIONS (user '${REPL_USER}', password '${REPL_PASSWORD}');
            IMPORT FOREIGN SCHEMA public LIMIT TO (users, orders, order_items)
                FROM SERVER remote_node_a INTO public;
            ALTER FOREIGN TABLE IF EXISTS users RENAME TO remote_users;
            ALTER FOREIGN TABLE IF EXISTS orders RENAME TO remote_orders;
            ALTER FOREIGN TABLE IF EXISTS order_items RENAME TO remote_order_items;
        END IF;
    END \$\$;
" 2>/dev/null || true

echo "✔ Bidirectional Logical Replication cluster setup complete!"
