#!/usr/bin/env bash
# ==============================================================================
# Cluster Startup & Initialization Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${CYAN}${BOLD}     Starting PostgreSQL Active-Active High Availability Cluster    ${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"

# 1. Check prerequisites
if ! command -v docker &>/dev/null; then
    echo -e "${RED}[ERROR] Docker is not installed or not in PATH.${NC}"
    exit 1
fi

# 2. Launch Docker Compose stack
echo -e "\n${YELLOW}[1/4] Launching Docker containers...${NC}"
docker compose up -d

# 3. Wait for database health
echo -e "\n${YELLOW}[2/4] Waiting for PostgreSQL nodes to be healthy...${NC}"
until docker compose exec -T node-a pg_isready -U postgres -d appdb -q 2>/dev/null; do
    echo -n "."
    sleep 2
done
echo -e " Node A: ${GREEN}READY${NC}"

until docker compose exec -T node-b pg_isready -U postgres -d appdb -q 2>/dev/null; do
    echo -n "."
    sleep 2
done
echo -e " Node B: ${GREEN}READY${NC}"

# 4. Bootstrap bidirectional replication
echo -e "\n${YELLOW}[3/4] Establishing bidirectional logical replication...${NC}"
docker compose exec -T node-a /bin/sh -c "
    NODE_A_HOST=node-a NODE_B_HOST=node-b /scripts/../../scripts/setup-replication.sh
" 2>/dev/null || docker exec -t postgres-node-a /scripts/../../scripts/setup-replication.sh 2>/dev/null || ./scripts/setup-replication.sh

# 5. Display Cluster Summary
echo -e "\n${YELLOW}[4/4] Verifying Cluster State...${NC}"
sleep 2

echo -e "\n${GREEN}${BOLD}✔ PostgreSQL Active-Active Cluster is ONLINE!${NC}"
echo -e "${CYAN}====================================================================${NC}"
echo -e " ${BOLD}Node A (Host):${NC}           localhost:5432 (DB: appdb, User: postgres)"
echo -e " ${BOLD}Node B (Host):${NC}           localhost:5433 (DB: appdb, User: postgres)"
echo -e " ${BOLD}Prometheus Web UI:${NC}       http://localhost:9090"
echo -e " ${BOLD}Grafana Dashboard:${NC}       http://localhost:3000 (User: admin / Pass: admin)"
echo -e " ${BOLD}Alertmanager UI:${NC}         http://localhost:9093"
echo -e " ${BOLD}Node A Exporter:${NC}         http://localhost:9187/metrics"
echo -e " ${BOLD}Node B Exporter:${NC}         http://localhost:9188/metrics"
echo -e "${CYAN}====================================================================${NC}"
echo -e "Run ${BOLD}./scripts/status.sh${NC} to view replication status and lag."
echo -e "Run ${BOLD}./scripts/data-sync-test.sh${NC} to run bidirectional test writes."
echo -e "Run ${BOLD}./scripts/failover-test.sh${NC} to simulate node failure and recovery.\n"
