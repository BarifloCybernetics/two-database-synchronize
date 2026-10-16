#!/usr/bin/env bash
# ==============================================================================
# Cluster Status & Health Monitoring Dashboard
# Supports Local and Cross-Network Static IP Deployments
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

export PGPASSWORD="postgres_master_pw"

NODE_A_HOST="${NODE_A_HOST:-127.0.0.1}"
NODE_A_PORT="${NODE_A_PORT:-5432}"
NODE_B_HOST="${NODE_B_HOST:-127.0.0.1}"
NODE_B_PORT="${NODE_B_PORT:-5433}"

# If --remote or --static flag passed or environment specified, use static IPs from .env
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
echo -e "${CYAN}${BOLD}           POSTGRESQL ACTIVE-ACTIVE CLUSTER STATUS                  ${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "Node A Target: ${NODE_A_HOST}:${NODE_A_PORT}"
echo -e "Node B Target: ${NODE_B_HOST}:${NODE_B_PORT}"

# 1. Container Status (if docker available locally)
echo -e "\n${BOLD}[1] Docker Containers:${NC}"
if command -v docker &>/dev/null; then
    docker compose -f "${PROJECT_ROOT}/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker ps --filter "name=postgres"
else
    echo "  (Docker CLI not present locally, checking network ports directly)"
fi

# 2. Database Reachability
echo -e "\n${BOLD}[2] Node Connectivity:${NC}"
if pg_isready -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -q 2>/dev/null; then
    echo -e "  Node A (${NODE_A_HOST}:${NODE_A_PORT}): ${GREEN}ONLINE${NC}"
else
    echo -e "  Node A (${NODE_A_HOST}:${NODE_A_PORT}): ${RED}OFFLINE / UNREACHABLE${NC}"
fi

if pg_isready -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -q 2>/dev/null; then
    echo -e "  Node B (${NODE_B_HOST}:${NODE_B_PORT}): ${GREEN}ONLINE${NC}"
else
    echo -e "  Node B (${NODE_B_HOST}:${NODE_B_PORT}): ${RED}OFFLINE / UNREACHABLE${NC}"
fi

# 3. Node A Replication Status
echo -e "\n${BOLD}[3] Node A Diagnostics (${NODE_A_HOST}:${NODE_A_PORT}):${NC}"
if pg_isready -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -q 2>/dev/null; then
    psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -c "
        SELECT 'Subscription' AS type, subname AS name, pid, received_lsn, last_msg_receipt_time FROM pg_stat_subscription
        UNION ALL
        SELECT 'Slot' AS type, slot_name AS name, active_pid AS pid, restart_lsn, NULL FROM pg_replication_slots;
    " || true
else
    echo "  (Node A not responding)"
fi

# 4. Node B Replication Status
echo -e "\n${BOLD}[4] Node B Diagnostics (${NODE_B_HOST}:${NODE_B_PORT}):${NC}"
if pg_isready -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -q 2>/dev/null; then
    psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -c "
        SELECT 'Subscription' AS type, subname AS name, pid, received_lsn, last_msg_receipt_time FROM pg_stat_subscription
        UNION ALL
        SELECT 'Slot' AS type, slot_name AS name, active_pid AS pid, restart_lsn, NULL FROM pg_replication_slots;
    " || true
else
    echo "  (Node B not responding)"
fi

# 5. Row Counts Comparison
echo -e "\n${BOLD}[5] Table Row Parity Check:${NC}"
printf "%-15s | %-15s | %-15s | %-10s\n" "Table" "Node A Count" "Node B Count" "Sync State"
printf "%s\n" "---------------------------------------------------------------"

for tbl in users orders order_items; do
    COUNT_A="ERR"
    COUNT_B="ERR"
    if pg_isready -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -q 2>/dev/null; then
        COUNT_A=$(psql -h "${NODE_A_HOST}" -p "${NODE_A_PORT}" -U postgres -d appdb -t -A -c "SELECT count(*) FROM ${tbl};" 2>/dev/null || echo "ERR")
    fi
    if pg_isready -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -q 2>/dev/null; then
        COUNT_B=$(psql -h "${NODE_B_HOST}" -p "${NODE_B_PORT}" -U postgres -d appdb -t -A -c "SELECT count(*) FROM ${tbl};" 2>/dev/null || echo "ERR")
    fi

    if [[ "${COUNT_A}" == "${COUNT_B}" && "${COUNT_A}" != "ERR" ]]; then
        STATE="${GREEN}IN SYNC${NC}"
    else
        STATE="${RED}MISMATCH${NC}"
    fi
    printf "%-15s | %-15s | %-15s | " "${tbl}" "${COUNT_A}" "${COUNT_B}"
    echo -e "${STATE}"
done

echo -e "\n${CYAN}====================================================================${NC}\n"
