#!/usr/bin/env bash
# ==============================================================================
# Bidirectional Logical Replication Data Sync Verification Test
# Supports Local and Cross-Network Static IP Cluster Deployments
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

export PGPASSWORD="postgres_master_pw"

NODE_A_HOST="${NODE_A_HOST:-127.0.0.1}"
NODE_A_PORT="${NODE_A_PORT:-5432}"
NODE_B_HOST="${NODE_B_HOST:-127.0.0.1}"
NODE_B_PORT="${NODE_B_PORT:-5433}"

# If --remote or --static flag passed, load static IPs from .env
if [[ "${1:-}" == "--remote" || "${1:-}" == "--static" ]]; then
    if [[ -f "${PROJECT_ROOT}/node-a/.env" ]]; then
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/node-a/.env"
        NODE_A_HOST="${LOCAL_STATIC_IP:-127.0.0.1}"
        NODE_B_HOST="${REMOTE_STATIC_IP:-127.0.0.1}"
        NODE_B_PORT="${REMOTE_PORT:-5432}"
    fi
fi

echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${CYAN}${BOLD}    POSTGRESQL BIDIRECTIONAL REPLICATION DATA SYNC TEST             ${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "Testing Node A Target: ${NODE_A_HOST}:${NODE_A_PORT}"
echo -e "Testing Node B Target: ${NODE_B_HOST}:${NODE_B_PORT}"

# Test Batch Identifier
BATCH_ID="$(date +%s)"
USER_A="user_node_a_${BATCH_ID}"
EMAIL_A="user_a_${BATCH_ID}@test.local"
USER_B="user_node_b_${BATCH_ID}"
EMAIL_B="user_b_${BATCH_ID}@test.local"

# ------------------------------------------------------------------------------
# TEST 1: Write on Node A -> Verify Replicated to Node B
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 1] Writing record to Node A (${NODE_A_HOST}:${NODE_A_PORT})...${NC}"
T_START=$(date +%s%N)
USER_A_ID=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -t -A -c "
    INSERT INTO users (username, email, full_name, role, node_origin)
    VALUES ('${USER_A}', '${EMAIL_A}', 'Node A Tester', 'customer', 'node-a')
    RETURNING id;
")
echo "  Inserted on Node A with ID: ${USER_A_ID}"

echo -n "  Waiting for replication to Node B (${NODE_B_HOST}:${NODE_B_PORT})..."
SYNCED=0
for i in {1..20}; do
    EXISTS=$(psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -t -A -c "
        SELECT count(*) FROM users WHERE id = '${USER_A_ID}';
    " 2>/dev/null || echo "0")
    if [[ "${EXISTS}" == "1" ]]; then
        T_END=$(date +%s%N)
        LATENCY_MS=$(( (T_END - T_START) / 1000000 ))
        SYNCED=1
        echo -e " ${GREEN}[SUCCESS]${NC}"
        echo -e "  Replication Latency: ${BOLD}${LATENCY_MS} ms${NC}"
        break
    fi
    sleep 0.1
done

if [[ ${SYNCED} -eq 0 ]]; then
    echo -e " ${RED}[FAILED] Record failed to replicate to Node B!${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 2: Write on Node B -> Verify Replicated to Node A
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 2] Writing record to Node B (${NODE_B_HOST}:${NODE_B_PORT})...${NC}"
T_START=$(date +%s%N)
USER_B_ID=$(psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -t -A -c "
    INSERT INTO users (username, email, full_name, role, node_origin)
    VALUES ('${USER_B}', '${EMAIL_B}', 'Node B Tester', 'customer', 'node-b')
    RETURNING id;
")
echo "  Inserted on Node B with ID: ${USER_B_ID}"

echo -n "  Waiting for replication to Node A (${NODE_A_HOST}:${NODE_A_PORT})..."
SYNCED=0
for i in {1..20}; do
    EXISTS=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -t -A -c "
        SELECT count(*) FROM users WHERE id = '${USER_B_ID}';
    " 2>/dev/null || echo "0")
    if [[ "${EXISTS}" == "1" ]]; then
        T_END=$(date +%s%N)
        LATENCY_MS=$(( (T_END - T_START) / 1000000 ))
        SYNCED=1
        echo -e " ${GREEN}[SUCCESS]${NC}"
        echo -e "  Replication Latency: ${BOLD}${LATENCY_MS} ms${NC}"
        break
    fi
    sleep 0.1
done

if [[ ${SYNCED} -eq 0 ]]; then
    echo -e " ${RED}[FAILED] Record failed to replicate to Node A!${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 3: Order with Foreign Key & Subtable
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 3] Testing Relational Foreign Keys across nodes...${NC}"
ORDER_NUM="ORD-${BATCH_ID}"
ORDER_ID=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -t -A -c "
    INSERT INTO orders (order_number, user_id, total_amount, currency, status, node_origin)
    VALUES ('${ORDER_NUM}', '${USER_A_ID}', 249.99, 'USD', 'pending', 'node-a')
    RETURNING id;
")

psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -c "
    INSERT INTO order_items (order_id, product_name, quantity, unit_price)
    VALUES ('${ORDER_ID}', 'High Availability Router', 1, 249.99);
" > /dev/null

echo -n "  Verifying order and items replicated to Node B..."
sleep 0.5
REMOTE_ORDER=$(psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -t -A -c "
    SELECT count(*) FROM orders o JOIN order_items i ON o.id = i.order_id WHERE o.id = '${ORDER_ID}';
" 2>/dev/null || echo "0")

if [[ "${REMOTE_ORDER}" == "1" ]]; then
    echo -e " ${GREEN}[SUCCESS]${NC}"
else
    echo -e " ${RED}[FAILED]${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 4: Cross-Node Update Propagation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 4] Updating Order status on Node B -> verify on Node A...${NC}"
psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -c "
    UPDATE orders SET status = 'completed' WHERE id = '${ORDER_ID}';
" > /dev/null

sleep 0.5
UPDATED_STATUS=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -t -A -c "
    SELECT status FROM orders WHERE id = '${ORDER_ID}';
" 2>/dev/null || echo "error")

if [[ "${UPDATED_STATUS}" == "completed" ]]; then
    echo -e "  Status on Node A: ${GREEN}${UPDATED_STATUS}${NC} [SUCCESS]"
else
    echo -e "  Status on Node A: ${RED}${UPDATED_STATUS}${NC} [FAILED]"
    exit 1
fi

echo -e "\n${GREEN}${BOLD}✔ ALL BIDIRECTIONAL REPLICATION TESTS PASSED SUCCESSFULLY!${NC}\n"
