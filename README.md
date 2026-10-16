# PostgreSQL Active-Active High Availability Cluster (Multi-Network & Static IPs)

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16--alpine-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Prometheus](https://img.shields.io/badge/Prometheus-Monitoring-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-Dashboards-F46800?logo=grafana&logoColor=white)](https://grafana.com/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A production-grade, Docker-based **Active-Active PostgreSQL** database system designed for deployment across **different networks with separate static IPs** (e.g., Data Center 1 and Data Center 2, or Cloud VPC A and Cloud VPC B).

Both **Database Node A** and **Database Node B** are independently writable and continuously synchronize data in real-time using bidirectional logical replication with loop prevention (`origin = 'none'`).

Each database uses its dedicated `.env` configuration file to configure its local and remote static IPs, while automated health checks, WAL monitoring, cross-network reconciliation, and a complete Prometheus, Grafana, and Alertmanager stack ensure high resilience and visibility.

---

## Architecture Topology

```
   ┌─────────────────────────────────────────────────────────┐
   │                  CLIENT / APP ROUTING                   │
   │   postgresql://user:pass@192.168.1.10:5432,             │
   │               192.168.2.20:5432/appdb?target_session_   │
   │               attrs=read-write&load_balance_hosts=round │
   └───────────────────────────┬─────────────────────────────┘
                               │
               ┌───────────────┴───────────────┐
               ▼                               ▼
    SITE 1 / NETWORK A              SITE 2 / NETWORK B
 ┌───────────────────────┐       ┌───────────────────────┐
 │       Server A        │       │       Server B        │
 │ Static IP: 192.168.1.10│      │Static IP: 192.168.2.20│
 │  ───────────────────  │       │  ───────────────────  │
 │  PostgreSQL Node A    │       │  PostgreSQL Node B    │
 │  (Port 5432)          │◄─────►│  (Port 5432)          │
 │  Publication: pub_a   │  WAN  │  Publication: pub_b   │
 │  Subscription: sub_b  │Logical│  Subscription: sub_a  │
 │  (origin = 'none')    │ Stream│  (origin = 'none')    │
 │  ───────────────────  │ (5432)│  ───────────────────  │
 │  Exporter A (9187)    │       │  Exporter B (9187)    │
 └───────────┬───────────┘       └───────────┬───────────┘
             │                               │
             └───────────────┬───────────────┘
                             ▼
 ┌───────────────────────────────────────────────────────┐
 │               CENTRAL OBSERVABILITY SERVER            │
 │  Prometheus (9090) ──► Grafana (3000) ──► Alertmgr   │
 └───────────────────────────────────────────────┬───────┘
                                                 ▼
                                         Telegram & Email
```

---

## Project Structure

```
postgres-active-active/
│
├── README.md                           # Master documentation and multi-site deployment guide
├── .gitignore                          # Git ignore rules for data, backups, and logs
├── docker-compose.yml                  # All-in-one local test stack
│
├── node-a/                             # Server A / Site 1 Package
│   ├── .env                            # Static IP config (LOCAL=192.168.1.10, REMOTE=192.168.2.20)
│   ├── docker-compose.yml              # Standalone container definition for Server A
│   ├── init/                           # Schema init & replication publication
│   │   ├── 01-init.sql                 # Node origin tag & cluster audit table
│   │   ├── 02-publication.sql          # Publication pub_node_a
│   │   └── 03-replication-user.sql     # Dedicated replicator & pg_monitor role
│   ├── postgres/
│   │   ├── postgresql.conf             # Tuned PG16 engine (wal_level=logical, track_commit_timestamp)
│   │   └── pg_hba.conf                 # Host authentication permitting remote static IP
│   └── scripts/
│       ├── health-check.sh             # Tests connectivity to local and remote static IP
│       ├── setup-subscription.sh       # Establishes subscription to remote Node B
│       ├── replication-status.sh       # LSN lag and replication slots diagnostics
│       └── reconciliation.sh           # Local-to-remote parity check
│
├── node-b/                             # Server B / Site 2 Package
│   ├── .env                            # Static IP config (LOCAL=192.168.2.20, REMOTE=192.168.1.10)
│   ├── docker-compose.yml              # Standalone container definition for Server B
│   ├── init/                           # Schema init & replication publication
│   │   ├── 01-init.sql                 # Node origin tag & cluster audit table
│   │   ├── 02-publication.sql          # Publication pub_node_b
│   │   └── 03-replication-user.sql     # Dedicated replicator & pg_monitor role
│   ├── postgres/
│   │   ├── postgresql.conf             # Tuned PG16 engine (wal_level=logical, track_commit_timestamp)
│   │   └── pg_hba.conf                 # Host authentication permitting remote static IP
│   └── scripts/
│       ├── health-check.sh             # Tests connectivity to local and remote static IP
│       ├── setup-subscription.sh       # Establishes subscription to remote Node A
│       ├── replication-status.sh       # LSN lag and replication slots diagnostics
│       └── reconciliation.sh           # Local-to-remote parity check
│
├── database/                           # Database Schema & Reconciliation Engine
│   ├── schema/
│   │   ├── 001-users.sql               # UUID primary keys, versioning, REPLICA IDENTITY FULL
│   │   ├── 002-orders.sql              # Relational order headers and order items
│   │   └── 003-indexes.sql             # Composite indexes & performance optimizations
│   └── reconciliation/
│       ├── compare-count.sql           # Table row count and MD5 checksum query
│       ├── find-missing-a.sql          # FDW query detecting records missing in Node A
│       ├── find-missing-b.sql          # FDW query detecting records missing in Node B
│       └── reconcile.sh                # Cross-node reconciliation & auto-healing CLI
│
├── monitoring/                         # Observability Stack Configuration
│   ├── prometheus/
│   │   ├── prometheus.yml              # Scrapes Exporter A & B across static IPs
│   │   └── alert_rules.yml             # Replication lag, down node, and anomaly alerts
│   ├── grafana/
│   │   ├── dashboards/
│   │   │   ├── postgres-overview.json  # Comprehensive cluster health & throughput
│   │   │   └── replication-dashboard.json # LSN lag, slot retention, and worker diagnostics
│   │   └── provisioning/
│   │       ├── dashboards/dashboards.yml # Automatic dashboard loader
│   │       └── datasources/datasource.yml # Automatic Prometheus datasource setup
│   └── alertmanager/
│       └── alertmanager.yml            # Alert routing for Telegram Bot & SMTP Email
│
├── backup/                             # Disaster Recovery & Archival
│   ├── node-a/
│   │   ├── backup.sh                   # Compressed backup with SHA-256 and retention
│   │   └── restore.sh                  # Disaster recovery restoration script
│   └── node-b/
│       ├── backup.sh                   # Compressed backup with SHA-256 and retention
│       └── restore.sh                  # Disaster recovery restoration script
│
├── scripts/                            # Operational Management & Test Suite
│   ├── start.sh                        # Cluster startup & automated replication setup
│   ├── stop.sh                         # Graceful cluster shutdown and cleanup
│   ├── status.sh                       # Live terminal dashboard (supports --remote flag)
│   ├── setup-replication.sh            # Automated bidirectional replication handshake
│   ├── data-sync-test.sh               # Automated bidirectional write verification test
│   └── failover-test.sh                # Automated failure, failover & recovery test
│
└── docs/                               # Detailed Technical Documentation
    ├── architecture.md                 # System architecture, static IP & firewall setup
    ├── replication.md                  # PostgreSQL 16 logical replication guide
    ├── failover.md                     # High availability, failover and load balancing
    ├── reconciliation.md               # Data drift detection and auto-healing guide
    └── disaster-recovery.md            # RPO/RTO metrics and disaster recovery runbook
```

---

## Automated 1-Command Installation (Zero-Touch Setup)

The project includes a master installer script `install.sh` that **automatically checks, installs, and configures everything**—including Docker, Docker Compose, systemd, firewall rules, static IPs, and the entire PostgreSQL cluster:

```bash
chmod +x install.sh
./install.sh
```

### Headless / Automated CLI Options:

- **100% Automated All-in-One Cluster (Local machine / Single server)**:
  ```bash
  ./install.sh --all-in-one
  ```

- **100% Automated Server A (Site 1 / Network A with Static IP)**:
  ```bash
  ./install.sh --node-a 192.168.1.10 192.168.2.20
  ```

- **100% Automated Server B (Site 2 / Network B with Static IP)**:
  ```bash
  ./install.sh --node-b 192.168.2.20 192.168.1.10
  ```

When deploying on two separate servers, the included `cluster-auto-join` daemon automatically detects when the remote node comes online and establishes the bidirectional replication link without requiring manual SQL commands!

---

## Manual Deployment Guide: Two Different Networks (Static IPs)

### Step 1: Configure Environment Variables

Edit `node-a/.env` on **Server A** (e.g. Static IP `192.168.1.10`):
```ini
LOCAL_STATIC_IP=192.168.1.10
LOCAL_PORT=5432
REMOTE_STATIC_IP=192.168.2.20
REMOTE_PORT=5432
REPLICATION_SSL_MODE=prefer
```

Edit `node-b/.env` on **Server B** (e.g. Static IP `192.168.2.20`):
```ini
LOCAL_STATIC_IP=192.268.2.20
LOCAL_PORT=5432
REMOTE_STATIC_IP=192.168.1.10
REMOTE_PORT=5432
REPLICATION_SSL_MODE=prefer
```

---

### Step 2: Open Firewalls / Security Groups

Allow TCP port `5432` between the two static IPs:

**On Server A (`192.168.1.10`):**
```bash
sudo ufw allow from 192.168.2.20 to any port 5432 proto tcp comment 'PG from Node B'
```

**On Server B (`192.168.2.20`):**
```bash
sudo ufw allow from 192.168.1.10 to any port 5432 proto tcp comment 'PG from Node A'
```

---

### Step 3: Deploy Databases

**On Server A:**
```bash
cd node-a
docker compose up -d
```

**On Server B:**
```bash
cd node-b
docker compose up -d
```

---

### Step 4: Establish Bidirectional Replication

Once both containers are running and accepting connections:

**On Server A:**
```bash
./node-a/scripts/setup-subscription.sh
```

**On Server B:**
```bash
./node-b/scripts/setup-subscription.sh
```

Both nodes will connect across the network to each other's static IP and establish bidirectional logical replication with `origin = 'none'`!

---

### Step 5: Verify Cross-Network Replication

Run tests from either server or your management workstation:

```bash
# Check status across static IPs
./scripts/status.sh --remote

# Test cross-network write sync and measure latency
./scripts/data-sync-test.sh --remote

# Inspect data parity across static IPs
./database/reconciliation/reconcile.sh --check
```

---

## Continuous 1-Minute Auto-Reconciliation (Zero Duplicates)

The system automatically checks both databases against each other **every 1 minute (60 seconds)**, identifies any records present in one node but missing in the other, and reconciles **only the missing data with strictly zero duplicate entries**:

### How It Guarantees Zero Duplicates:
1. **Target Key Isolation**: Calculates exact missing primary keys using `comm -23` and `comm -13` set differences.
2. **Atomic Staging & `ON CONFLICT DO NOTHING`**: Rows are loaded into a temporary staging table, then inserted with:
   ```sql
   INSERT INTO target_table
   SELECT * FROM temp_reconcile_stage
   ON CONFLICT (id) DO NOTHING;
   ```
3. **Foreign Key Dependency Sorting**: Reconciles `users` first, then `orders`, then `order_items`.

### Execution Options:
- **Built-in Docker Daemon (Automatic)**:
  The `reconciliation-service` container in `docker-compose.yml` runs continuously in the background every 60 seconds automatically.
- **Manual CLI Daemon**:
  ```bash
  ./database/reconciliation/reconcile.sh --daemon 60
  ```
- **One-Shot Manual Fix**:
  ```bash
  ./database/reconciliation/reconcile.sh --fix
  ```

---

## Local Development / Single-Host Simulation

For rapid testing on a single machine:
```bash
./scripts/start.sh
./scripts/status.sh
./scripts/data-sync-test.sh
./scripts/failover-test.sh
```

---

## Access Endpoints

| Component | Network Address | Credentials |
| :--- | :--- | :--- |
| **Node A (Server A)** | `http://192.168.1.10:5432` | User: `postgres`, Password: `postgres_master_pw`, DB: `appdb` |
| **Node B (Server B)** | `http://192.168.2.20:5432` | User: `postgres`, Password: `postgres_master_pw`, DB: `appdb` |
| **Grafana Dashboard** | `http://<MONITOR_IP>:3000` | User: `admin`, Password: `admin` |
| **Prometheus UI** | `http://<MONITOR_IP>:9090` | Scrapes exporters on `192.168.1.10:9187` and `192.168.2.20:9187` |
| **Alertmanager UI** | `http://<MONITOR_IP>:9093` | Manages Telegram and Email alerts |
| **Node A Exporter** | `http://192.168.1.10:9187/metrics` | Prometheus metrics endpoint |
| **Node B Exporter** | `http://192.168.2.20:9187/metrics` | Prometheus metrics endpoint |
# two-database-synchronize
