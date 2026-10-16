#!/usr/bin/env bash
# ==============================================================================
# PostgreSQL Active-Active High Availability Cluster Automated Installer
# Installs Docker, dependencies, configures static IPs, firewalls, and starts cluster
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
====================================================================
     POSTGRESQL ACTIVE-ACTIVE CLUSTER AUTOMATED INSTALLER
          PostgreSQL 16 Bidirectional Logical Replication
====================================================================
EOF
    echo -e "${NC}"
}

# ------------------------------------------------------------------------------
# 1. Dependency Auto-Installation (Docker & Docker Compose)
# ------------------------------------------------------------------------------
install_docker_prerequisites() {
    echo -e "${BLUE}[Step 1/5] Checking Docker & Docker Compose dependencies...${NC}"

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}Docker is not installed. Installing Docker automatically...${NC}"
        if command -v curl &>/dev/null; then
            curl -fsSL https://get.docker.com | sudo sh
        elif command -v wget &>/dev/null; then
            wget -qO- https://get.docker.com | sudo sh
        else
            echo -e "${RED}[ERROR] Neither curl nor wget found. Please install curl or wget first.${NC}"
            exit 1
        fi

        # Enable and start docker service
        if command -v systemctl &>/dev/null; then
            sudo systemctl enable --now docker || true
        fi

        # Add current user to docker group
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        echo -e "${GREEN}✔ Docker installed successfully.${NC}"
    else
        echo -e "${GREEN}✔ Docker is already installed: $(docker --version)${NC}"
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${YELLOW}Docker Compose plugin missing. Installing compose plugin...${NC}"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y docker-compose-plugin
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y docker-compose-plugin
        elif command -v yum &>/dev/null; then
            sudo yum install -y docker-compose-plugin
        fi
    else
        echo -e "${GREEN}✔ Docker Compose is ready: $(docker compose version)${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 2. Host Network Auto-Detection
# ------------------------------------------------------------------------------
detect_host_ip() {
    local detected_ip=""
    if command -v ip &>/dev/null; then
        detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d ' ' || true)
    fi
    if [[ -z "${detected_ip}" ]]; then
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    fi
    echo "${detected_ip}"
}

# ------------------------------------------------------------------------------
# 3. Configure Firewall (UFW / Firewalld)
# ------------------------------------------------------------------------------
configure_firewall() {
    local role="$1"
    local remote_ip="${2:-}"

    if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
        echo -e "${BLUE}[Firewall] Configuring UFW rules...${NC}"
        if [[ "${role}" == "all-in-one" ]]; then
            sudo ufw allow 5432/tcp comment 'PostgreSQL Node A' || true
            sudo ufw allow 5433/tcp comment 'PostgreSQL Node B' || true
            sudo ufw allow 3000/tcp comment 'Grafana UI' || true
            sudo ufw allow 9090/tcp comment 'Prometheus UI' || true
        elif [[ -n "${remote_ip}" ]]; then
            sudo ufw allow from "${remote_ip}" to any port 5432 proto tcp comment 'PostgreSQL Replication Peer' || true
            sudo ufw allow 9187/tcp comment 'Postgres Exporter' || true
        fi
        echo -e "${GREEN}✔ Firewall configured.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 4. Installation Profiles
# ------------------------------------------------------------------------------
install_all_in_one() {
    echo -e "\n${CYAN}${BOLD}=== Installing Full Local Active-Active Cluster (All-in-One) ===${NC}"
    configure_firewall "all-in-one"

    echo -e "${BLUE}[Step 2/5] Setting script execution permissions...${NC}"
    chmod +x "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/node-*/scripts/*.sh "${SCRIPT_DIR}"/database/reconciliation/*.sh "${SCRIPT_DIR}"/backup/*/*.sh

    echo -e "${BLUE}[Step 3/5] Starting Docker Compose Cluster...${NC}"
    docker compose up -d

    echo -e "${BLUE}[Step 4/5] Waiting for database healthchecks...${NC}"
    until docker compose exec -T node-a pg_isready -U postgres -d appdb -q 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo -e "\n Node A: ${GREEN}READY${NC}"

    until docker compose exec -T node-b pg_isready -U postgres -d appdb -q 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo -e " Node B: ${GREEN}READY${NC}"

    echo -e "${BLUE}[Step 5/5] Bootstrapping bidirectional logical replication...${NC}"
    ./scripts/setup-replication.sh

    echo -e "\n${GREEN}${BOLD}✔ CLUSTER INSTALLATION COMPLETE & OPERATIONAL!${NC}"
    print_summary "all-in-one"
}

install_node_server() {
    local node="$1"          # "node-a" or "node-b"
    local local_ip="$2"
    local remote_ip="$3"
    local other_node="node-b"
    if [[ "${node}" == "node-b" ]]; then other_node="node-a"; fi

    echo -e "\n${CYAN}${BOLD}=== Installing ${node^^} (Multi-Site Cross-Network Mode) ===${NC}"
    echo -e " Local Server IP:  ${BOLD}${local_ip}${NC}"
    echo -e " Remote Server IP: ${BOLD}${remote_ip}${NC}"

    # Update .env
    cat > "${SCRIPT_DIR}/${node}/.env" << EOF
NODE_NAME=${node}
NODE_ROLE=active
CONTAINER_NAME=postgres-${node}

LOCAL_STATIC_IP=${local_ip}
LOCAL_PORT=5432
REMOTE_STATIC_IP=${remote_ip}
REMOTE_PORT=5432
REMOTE_HOST=${remote_ip}

POSTGRES_DB=appdb
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres_master_pw
POSTGRES_PORT=5432
HOST_PORT=5432

REPLICATION_USER=replicator
REPLICATION_PASSWORD=replicator_secure_pw_123

REMOTE_NODE_NAME=${other_node}
REMOTE_DB=appdb
REMOTE_REPLICATION_USER=replicator
REMOTE_REPLICATION_PASSWORD=replicator_secure_pw_123
REPLICATION_SSL_MODE=prefer

PUBLICATION_NAME=pub_${node//-/_}
REMOTE_PUBLICATION_NAME=pub_${other_node//-/_}
SUBSCRIPTION_NAME=sub_${other_node//-/_}_to_${node//-/_}
REPLICATION_SLOT_NAME=sub_${other_node//-/_}_to_${node//-/_}

MAX_ALLOWED_LAG_BYTES=10485760
HEALTH_CHECK_INTERVAL_SEC=10
RECONCILIATION_CRON="0 */2 * * *"

TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
SMTP_SMARTHOST=smtp.example.com:587
SMTP_FROM=alerts@ha-postgres.local
SMTP_AUTH_USER=
SMTP_AUTH_PASSWORD=
ALERT_EMAIL_TO=dba-team@example.com
EOF

    configure_firewall "${node}" "${remote_ip}"

    echo -e "${BLUE}[Step 2/5] Making scripts executable...${NC}"
    chmod +x "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}/${node}"/scripts/*.sh "${SCRIPT_DIR}"/database/reconciliation/*.sh "${SCRIPT_DIR}/backup/${node}"/*.sh

    echo -e "${BLUE}[Step 3/5] Starting ${node} Docker containers...${NC}"
    (cd "${SCRIPT_DIR}/${node}" && docker compose up -d)

    echo -e "${BLUE}[Step 4/5] Waiting for PostgreSQL engine...${NC}"
    until docker exec -i "postgres-${node}" pg_isready -U postgres -d appdb -q 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo -e "\n ${node^^}: ${GREEN}READY${NC}"

    echo -e "${BLUE}[Step 5/5] Launching automatic replication connector...${NC}"
    # Run setup-subscription if remote node is already up, or launch auto-cluster-join in background
    if pg_isready -h "${remote_ip}" -p 5432 -U replicator -d appdb -q 2>/dev/null; then
        echo -e "${GREEN}Remote peer is reachable! Establishing replication link now...${NC}"
        "${SCRIPT_DIR}/${node}/scripts/setup-subscription.sh" || true
    else
        echo -e "${YELLOW}Remote peer (${remote_ip}) is not online yet.${NC}"
        echo -e "Starting background auto-join daemon. It will automatically connect as soon as the other node is installed!"
        nohup "${SCRIPT_DIR}/scripts/auto-cluster-join.sh" > "${SCRIPT_DIR}/${node}/auto-join.log" 2>&1 &
    fi

    echo -e "\n${GREEN}${BOLD}✔ ${node^^} INSTALLATION COMPLETE!${NC}"
    print_summary "${node}" "${local_ip}"
}

print_summary() {
    local mode="$1"
    local local_ip="${2:-127.0.0.1}"

    echo -e "\n${CYAN}====================================================================${NC}"
    echo -e " ${BOLD}ACCESS SUMMARY & CONNECTION STRINGS${NC}"
    echo -e "${CYAN}====================================================================${NC}"
    if [[ "${mode}" == "all-in-one" ]]; then
        echo -e "  Database Node A:    localhost:5432 (appdb / postgres / postgres_master_pw)"
        echo -e "  Database Node B:    localhost:5433 (appdb / postgres / postgres_master_pw)"
        echo -e "  Grafana Dashboard:  http://localhost:3000 (admin / admin)"
        echo -e "  Prometheus Web UI:  http://localhost:9090"
        echo -e "  Alertmanager UI:    http://localhost:9093"
    else
        echo -e "  Installed Node:     ${mode^^} on ${local_ip}:5432"
        echo -e "  Database:           appdb"
        echo -e "  User / Password:    postgres / postgres_master_pw"
        echo -e "  Metrics Exporter:   http://${local_ip}:9187/metrics"
    fi
    echo -e "${CYAN}====================================================================${NC}"
    echo -e "Useful Commands:"
    echo -e "  Check Status:       ${BOLD}./scripts/status.sh${NC}"
    echo -e "  Test Sync Writes:   ${BOLD}./scripts/data-sync-test.sh${NC}"
    echo -e "  Check Data Parity:  ${BOLD}./database/reconciliation/reconcile.sh --check${NC}"
    echo -e "${CYAN}====================================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# 5. CLI Arguments & Interactive Selection
# ------------------------------------------------------------------------------
banner
install_docker_prerequisites

MODE="${1:-}"

if [[ "${MODE}" == "--all-in-one" || "${MODE}" == "--auto" || "${MODE}" == "-a" ]]; then
    install_all_in_one
    exit 0
elif [[ "${MODE}" == "--node-a" ]]; then
    LOCAL_IP="${2:-$(detect_host_ip)}"
    REMOTE_IP="${3:-192.168.2.20}"
    install_node_server "node-a" "${LOCAL_IP}" "${REMOTE_IP}"
    exit 0
elif [[ "${MODE}" == "--node-b" ]]; then
    LOCAL_IP="${2:-$(detect_host_ip)}"
    REMOTE_IP="${3:-192.168.1.10}"
    install_node_server "node-b" "${LOCAL_IP}" "${REMOTE_IP}"
    exit 0
fi

# Interactive Menu
DETECTED_IP=$(detect_host_ip)

echo -e "Detected Local IP on this machine: ${BOLD}${DETECTED_IP}${NC}\n"
echo -e "Please select your deployment mode:"
echo -e "  ${BOLD}1)${NC} Full Local Active-Active Cluster (All-in-One on this machine)"
echo -e "  ${BOLD}2)${NC} Install Node A Server (Site 1 / Network A)"
echo -e "  ${BOLD}3)${NC} Install Node B Server (Site 2 / Network B)"
echo -e "  ${BOLD}4)${NC} Exit"
echo ""
read -r -p "Enter choice [1-4] (default: 1): " CHOICE
CHOICE="${CHOICE:-1}"

case "${CHOICE}" in
    1)
        install_all_in_one
        ;;
    2)
        read -r -p "Enter Static IP of THIS server [${DETECTED_IP}]: " L_IP
        L_IP="${L_IP:-${DETECTED_IP}}"
        read -r -p "Enter Static IP of REMOTE Node B server [192.168.2.20]: " R_IP
        R_IP="${R_IP:-192.168.2.20}"
        install_node_server "node-a" "${L_IP}" "${R_IP}"
        ;;
    3)
        read -r -p "Enter Static IP of THIS server [${DETECTED_IP}]: " L_IP
        L_IP="${L_IP:-${DETECTED_IP}}"
        read -r -p "Enter Static IP of REMOTE Node A server [192.168.1.10]: " R_IP
        R_IP="${R_IP:-192.168.1.10}"
        install_node_server "node-b" "${L_IP}" "${R_IP}"
        ;;
    4)
        echo "Exiting installer."
        exit 0
        ;;
    *)
        echo "Invalid selection. Running default All-in-One installation..."
        install_all_in_one
        ;;
esac
