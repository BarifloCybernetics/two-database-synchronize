#!/usr/bin/env bash
# ==============================================================================
# High Availability & Failover Resilience Test
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

echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${CYAN}${BOLD}    POSTGRESQL ACTIVE-ACTIVE FAILOVER & RESILIENCE TEST             ${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"

# ------------------------------------------------------------------------------
# STEP 1: Simulate Node A Failure (Downtime)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[Step 1] Simulating unexpected failure of Node A...${NC}"
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" stop node-a
echo -e "  Node A stopped. Verifying port 5432 is down..."
if ! pg_isready -h 127.0.0.1 -p 5432 -U postgres -d appdb -q 2>/dev/null; then
    echo -e "  Node A is confirmed: ${RED}OFFLINE${NC}"
fi

# ------------------------------------------------------------------------------
# STEP 2: Write Traffic Routed to Node B during Node A Outage
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[Step 2] Sending write traffic to survivor Node B (Port 5433)...${NC}"
FAILOVER_USER="offline_user_$(date +%s)"
FAILOVER_EMAIL="${FAILOVER_USER}@failover.local"

NODE_B_WRITE_ID=$(psql -h 127.0.0.1 -p 5433 -U postgres -d appdb -t -A -c "
    INSERT INTO users (username, email, full_name, role, node_origin)
    VALUES ('${FAILOVER_USER}', '${FAILOVER_EMAIL}', 'Surviving Node B User', 'customer', 'node-b')
    RETURNING id;
")
echo -e "  Write successfully committed to Node B! ID: ${BOLD}${NODE_B_WRITE_ID}${NC}"
echo -e "  ${GREEN}✔ Zero-downtime write availability confirmed on survivor node.${NC}"

# ------------------------------------------------------------------------------
# STEP 3: Recover Node A
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[Step 3] Restoring and recovering Node A...${NC}"
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" start node-a

echo -n "  Waiting for Node A to resume accepting connections..."
until pg_isready -h 127.0.0.1 -p 5432 -U postgres -d appdb -q 2>/dev/null; do
    echo -n "."
    sleep 1
done
echo -e " ${GREEN}ONLINE${NC}"

# ------------------------------------------------------------------------------
# STEP 4: Verify Catch-up / Resynchronization on Node A
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[Step 4] Verifying automatic catch-up of writes missed during downtime...${NC}"
CATCHUP_SUCCESS=0
for i in {1..20}; do
    RECORD_FOUND=$(psql -h 127.0.0.1 -p 5432 -U postgres -d appdb -t -A -c "
        SELECT count(*) FROM users WHERE id = '${NODE_B_WRITE_ID}';
    " 2>/dev/null || echo "0")

    if [[ "${RECORD_FOUND}" == "1" ]]; then
        CATCHUP_SUCCESS=1
        echo -e "  ${GREEN}✔ Record written during downtime successfully replicated to recovered Node A!${NC}"
        break
    fi
    sleep 0.5
done

if [[ ${CATCHUP_SUCCESS} -eq 0 ]]; then
    echo -e "  ${RED}✘ Failed: Record missed during downtime was not replicated!${NC}"
    exit 1
fi

echo -e "\n${GREEN}${BOLD}====================================================================${NC}"
echo -e "${GREEN}${BOLD}✔ FAILOVER & AUTOMATIC CATCH-UP RECOVERY VALIDATED SUCCESSFULLY!   ${NC}"
echo -e "${GREEN}${BOLD}====================================================================${NC}\n"
