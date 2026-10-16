#!/usr/bin/env bash
# ==============================================================================
# Cluster Shutdown Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "${1:-}" == "--volumes" || "${1:-}" == "-v" ]]; then
    echo -e "${RED}[WARNING] Stopping cluster and REMOVING all persistent volumes...${NC}"
    docker compose down -v
    echo -e "${GREEN}✔ Cluster and all volumes removed.${NC}"
elif [[ "${1:-}" == "--down" ]]; then
    echo -e "${YELLOW}Stopping and removing cluster containers (data preserved in volumes)...${NC}"
    docker compose down
    echo -e "${GREEN}✔ Cluster stopped and containers removed.${NC}"
else
    echo -e "${YELLOW}Stopping cluster containers gracefully...${NC}"
    docker compose stop
    echo -e "${GREEN}✔ Cluster paused. Run './scripts/start.sh' to resume.${NC}"
fi
