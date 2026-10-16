# System Architecture: PostgreSQL Active-Active High Availability Cluster

## 1. Overview & Multi-Site Cross-Network Deployment

This project implements a multi-master, **Active-Active PostgreSQL** architecture designed for cross-site deployment across **two different networks with independent static IPs** (e.g. Data Center 1 & Data Center 2, or Cloud VPC A & Cloud VPC B).

Both **Node A** and **Node B** accept concurrent read and write operations independently and continuously synchronize mutations using **Bidirectional Logical Replication** in PostgreSQL 16 with loop prevention (`origin = 'none'`).

```mermaid
flowchart TD
    subgraph NetA["Network A / Site 1 (Static IP: 192.168.1.10)"]
        subgraph ServerA["Server A (Host Port 5432)"]
            PGA["PostgreSQL 16 Node A"]
            PubA["Publication: pub_node_a"]
            SubA["Subscription: sub_node_b_to_a<br/>(origin = none)"]
            ExpA["postgres-exporter-a (Port 9187)"]
        end
        ClientA["App Clients (Site 1)"] -->|Local R/W| PGA
    end

    subgraph NetB["Network B / Site 2 (Static IP: 192.168.2.20)"]
        subgraph ServerB["Server B (Host Port 5432)"]
            PGB["PostgreSQL 16 Node B"]
            PubB["Publication: pub_node_b"]
            SubB["Subscription: sub_node_a_to_b<br/>(origin = none)"]
            ExpB["postgres-exporter-b (Port 9187)"]
        end
        ClientB["App Clients (Site 2)"] -->|Local R/W| PGB
    end

    subgraph Observability["Central / Dedicated Monitoring Server"]
        Prom["Prometheus (Port 9090)"]
        Graf["Grafana Dashboards (Port 3000)"]
        Alert["Alertmanager (Port 9093)"]
        Channels["Telegram / Email Alerts"]
    end

    PubA -.->|WAN / VPN Stream (TCP:5432)| SubB
    PubB -.->|WAN / VPN Stream (TCP:5432)| SubA

    ExpA -->|Scrape 192.168.1.10:9187| Prom
    ExpB -->|Scrape 192.168.2.20:9187| Prom
    Prom -->|Trigger Alerts| Alert
    Alert -->|Notify| Channels
    Graf -->|Query| Prom
```

---

## 2. Multi-Network Static IP Configuration

### Node A (`node-a/.env` on Server A)
```bash
LOCAL_STATIC_IP=192.168.1.10    # Static IP of Server A
LOCAL_PORT=5432
REMOTE_STATIC_IP=192.168.2.20   # Static IP of Server B
REMOTE_PORT=5432
REPLICATION_SSL_MODE=prefer
```

### Node B (`node-b/.env` on Server B)
```bash
LOCAL_STATIC_IP=192.168.2.20    # Static IP of Server B
LOCAL_PORT=5432
REMOTE_STATIC_IP=192.168.1.10   # Static IP of Server A
REMOTE_PORT=5432
REPLICATION_SSL_MODE=prefer
```

---

## 3. Firewall & Security Group Rules (Cross-Network Ingress)

When running across different networks, configure firewall rules (`ufw`, `iptables`, or AWS/GCP security groups) so that each server permits traffic from the other's static IP:

### On Server A (Static IP: `192.168.1.10`):
```bash
# Allow PostgreSQL replication and client traffic from Server B only
sudo ufw allow from 192.168.2.20 to any port 5432 proto tcp comment 'PostgreSQL from Node B'

# Allow Prometheus scraper from Monitoring server
sudo ufw allow from <MONITORING_SERVER_IP> to any port 9187 proto tcp comment 'Postgres Exporter A'
```

### On Server B (Static IP: `192.168.2.20`):
```bash
# Allow PostgreSQL replication and client traffic from Server A only
sudo ufw allow from 192.168.1.10 to any port 5432 proto tcp comment 'PostgreSQL from Node A'

# Allow Prometheus scraper from Monitoring server
sudo ufw allow from <MONITORING_SERVER_IP> to any port 9187 proto tcp comment 'Postgres Exporter B'
```

---

## 4. Host-Based Authentication (`pg_hba.conf`)

Both nodes use a tuned `pg_hba.conf` to explicitly allow replication and FDW query connections from the remote static IP with SCRAM-SHA-256 encrypted authentication:

```hba
# Allow logical replication from remote static IP
host    replication    replicator    0.0.0.0/0    scram-sha-256

# Allow FDW and reconciliation queries from remote static IP
host    appdb          replicator    0.0.0.0/0    scram-sha-256
host    appdb          postgres      0.0.0.0/0    scram-sha-256
```

---

## 5. Conflict Prevention & Primary Key Strategy

In standard single-primary setups, auto-incrementing serial IDs (`BIGSERIAL`) are trivial. In multi-master Active-Active setups across different networks, concurrent writes on Node A and Node B without coordination can create duplicate ID collisions.

To guarantee zero primary-key collisions across different networks:
1. **Universally Unique Identifiers (UUIDv4)** via PostgreSQL's native `gen_random_uuid()`:
   ```sql
   id UUID PRIMARY KEY DEFAULT gen_random_uuid()
   ```
2. **Node Origin Metadata**:
   Each row records the node that authored the write:
   ```sql
   node_origin VARCHAR(20) NOT NULL DEFAULT 'node-a'
   ```
3. **Optimistic Versioning & Microsecond Timestamps**:
   ```sql
   version INT NOT NULL DEFAULT 1,
   updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
   ```
4. **Full Replica Identity**:
   ```sql
   ALTER TABLE users REPLICA IDENTITY FULL;
   ALTER TABLE orders REPLICA IDENTITY FULL;
   ```
   `REPLICA IDENTITY FULL` causes the WAL stream to include the old row data in addition to the new row data for every `UPDATE` and `DELETE`, enabling exact match and conflict detection.

---

## 6. Logical Loop Prevention (`origin = 'none'`)

PostgreSQL 16 introduced the `origin` subscription parameter:
```sql
CREATE SUBSCRIPTION sub_node_b_to_a
    CONNECTION 'host=192.168.2.20 port=5432 dbname=appdb user=replicator password=replicator_secure_pw_123 sslmode=prefer'
    PUBLICATION pub_node_b
    WITH (copy_data = false, create_slot = true, origin = 'none');
```
Setting `origin = 'none'` instructs the subscription to **only apply changes that have no replication origin**, which means changes that were directly committed on the publisher. Rows replicated to the publisher from another node are skipped, completely eliminating the loop!
