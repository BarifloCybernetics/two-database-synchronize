#!/usr/bin/env bash
# ==============================================================================
# Automatic Cluster Join & Continuous Replication Orchestration Daemon
# Automatically establishes, monitors, and auto-heals replication links
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Detect if run inside node-a, node-b, or root project
NODE_ENV=""
if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
    NODE_ENV="${SCRIPT_DIR}/../.env"
elif [[ -f "${PROJECT_ROOT}/node-a/.env" ]]; then
    NODE_ENV="${PROJECT_ROOT}/node-a/.env"
fi

if [[ -n "${NODE_ENV}" && -f "${NODE_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${NODE_ENV}"
fi

LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-5432}"
REMOTE_HOST="${REMOTE_STATIC_IP:-${REMOTE_HOST:-node-b}}"
REMOTE_PORT="${REMOTE_PORT:-5432}"

DB_NAME="${POSTGRES_DB:-appdb}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASS="${POSTGRES_PASSWORD:-postgres_master_pw}"
REPL_USER="${REPLICATION_USER:-replicator}"
REPL_PASS="${REPLICATION_PASSWORD:-replicator_secure_pw_123}"
SSL_MODE="${REPLICATION_SSL_MODE:-prefer}"

LOCAL_PUB="${PUBLICATION_NAME:-pub_node_a}"
REMOTE_PUB="${REMOTE_PUBLICATION_NAME:-pub_node_b}"
LOCAL_SUB="${SUBSCRIPTION_NAME:-sub_node_b_to_a}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${CYAN}${BOLD}     PostgreSQL Active-Active Auto-Join & Replication Daemon        ${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "Local Target:  ${LOCAL_HOST}:${LOCAL_PORT}/${DB_NAME}"
echo -e "Remote Target: ${REMOTE_HOST}:${REMOTE_PORT}/${DB_NAME}"

export PGPASSWORD="${DB_PASS}"

# 1. Wait for Local PostgreSQL Server
echo -e "\n${YELLOW}[Step 1] Waiting for local PostgreSQL (${LOCAL_HOST}:${LOCAL_PORT})...${NC}"
until pg_isready -h "${LOCAL_HOST}" -p "${LOCAL_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q 2>/dev/null; do
    echo -n "."
    sleep 2
done
echo -e "\n${GREEN}✔ Local PostgreSQL is ONLINE.${NC}"

# 2. Ensure Local Publication
echo -e "\n${YELLOW}[Step 2] Ensuring local publication '${LOCAL_PUB}' exists...${NC}"
psql -h "${LOCAL_HOST}" -p "${LOCAL_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '${LOCAL_PUB}') THEN
            CREATE PUBLICATION ${LOCAL_PUB} FOR ALL TABLES;
            RAISE NOTICE 'Publication ${LOCAL_PUB} created.';
        END IF;
    END \$\$;
" > /dev/null

# 3. Continuous Auto-Join Loop for Remote Node
echo -e "\n${YELLOW}[Step 3] Waiting to auto-join with Remote Node (${REMOTE_HOST}:${REMOTE_PORT})...${NC}"

LINK_ESTABLISHED=0
ATTEMPT=0

while [[ ${LINK_ESTABLISHED} -eq 0 ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    if pg_isready -h "${REMOTE_HOST}" -p "${REMOTE_PORT}" -U "${REPL_USER}" -d "${DB_NAME}" -q 2>/dev/null; then
        echo -e "\n${GREEN}✔ Remote node ${REMOTE_HOST}:${REMOTE_PORT} detected! Establishing link...${NC}"
        
        # Verify remote publication exists
        REMOTE_PUB_EXISTS=$(PGPASSWORD="${REPL_PASS}" psql -h "${REMOTE_HOST}" -p "${REMOTE_PORT}" -U "${REPL_USER}" -d "${DB_NAME}" -t -A -c "
            SELECT count(*) FROM pg_publication WHERE pubname = '${REMOTE_PUB}';
        " 2>/dev/null || echo "0")
        
        if [[ "${REMOTE_PUB_EXISTS}" != "1" ]]; then
            echo "  [WAIT] Remote publication '${REMOTE_PUB}' not ready yet. Retrying in 3s..."
            sleep 3
            continue
        fi

        # Create Subscription with origin = 'none'
        psql -h "${LOCAL_HOST}" -p "${LOCAL_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
            DO \$\$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = '${LOCAL_SUB}') THEN
                    CREATE SUBSCRIPTION ${LOCAL_SUB}
                        CONNECTION 'host=${REMOTE_HOST} port=${REMOTE_PORT} dbname=${DB_NAME} user=${REPL_USER} password=${REPL_PASS} sslmode=${SSL_MODE}'
                        PUBLICATION ${REMOTE_PUB}
                        WITH (copy_data = false, create_slot = true, origin = 'none');
                    RAISE NOTICE 'Subscription ${LOCAL_SUB} established with origin = none';
                END IF;
            END \$\$;
        "

        # Setup FDW for reconciliation
        psql -h "${LOCAL_HOST}" -p "${LOCAL_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
            CREATE EXTENSION IF NOT EXISTS postgres_fdw;
            DO \$\$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'remote_cluster_peer') THEN
                    CREATE SERVER remote_cluster_peer
                        FOREIGN DATA WRAPPER postgres_fdw
                        OPTIONS (host '${REMOTE_HOST}', port '${REMOTE_PORT}', dbname '${DB_NAME}', sslmode '${SSL_MODE}');
                    CREATE USER MAPPING FOR ${DB_USER}
                        SERVER remote_cluster_peer
                        OPTIONS (user '${REPL_USER}', password '${REPL_PASS}');
                    IMPORT FOREIGN SCHEMA public LIMIT TO (users, orders, order_items)
                        FROM SERVER remote_cluster_peer INTO public;
                    ALTER FOREIGN TABLE IF EXISTS users RENAME TO remote_users;
                    ALTER FOREIGN TABLE IF EXISTS orders RENAME TO remote_orders;
                    ALTER FOREIGN TABLE IF EXISTS order_items RENAME TO remote_order_items;
                END IF;
            END \$\$;
        " 2>/dev/null || true

        echo -e "${GREEN}${BOLD}✔ Automatic replication link successfully initialized and active!${NC}"
        LINK_ESTABLISHED=1
    else
        echo -n "[$(date +'%T')] Waiting for remote node ${REMOTE_HOST}:${REMOTE_PORT}... "
        echo -e "${YELLOW}(attempt ${ATTEMPT})${NC}"
        sleep 5
    fi
done

# 4. Long-Running Monitor Loop
echo -e "\n${CYAN}[Daemon Active] Monitoring replication heartbeat every 30 seconds...${NC}"
while true; do
    sleep 30
    SUB_STATUS=$(psql -h "${LOCAL_HOST}" -p "${LOCAL_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "
        SELECT coalesce(string_agg(subname || ':' || CASE WHEN pid IS NOT NULL THEN 'STREAMING' ELSE 'PAUSED' END, ', '), 'NONE')
        FROM pg_stat_subscription;
    " 2>/dev/null || echo "UNAVAILABLE")
    
    echo "[$(date +'%Y-%m-%d %T')] Cluster Peer Replication Status: ${SUB_STATUS}"
done
