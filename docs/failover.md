# High Availability & Failover Architecture

## 1. Active-Active vs Active-Passive Failover

In traditional **Active-Passive** architectures:
1. Primary node crashes.
2. An orchestrator (Patroni, repmgr) detects downtime.
3. Standby node is promoted to primary (`pg_ctl promote`).
4. Applications experience write downtime during the promotion window (10–60 seconds).

In **Active-Active** architectures:
- **Both nodes are already active and writable.**
- No promotion step is required.
- If Node A fails, client traffic simply shifts to Node B. Node B continues processing writes without delay.
- When Node A recovers, it reconnects to Node B's replication slot and catches up on all transactions committed during its downtime.

---

## 2. Client Connection Routing Strategies

### Option A: Native Multi-Host Connection String (Zero Extra Infrastructure)
Modern PostgreSQL client drivers (`libpq`, JDBC, Python `psycopg3`, Go `pgx`, Node.js `pg`) natively support multiple host addresses with automatic fallback:

```ini
postgresql://postgres:postgres_master_pw@localhost:5432,localhost:5433/appdb?target_session_attrs=read-write&load_balance_hosts=round-robin
```

- If `localhost:5432` goes down, the client transparently retries and connects to `localhost:5433`.
- `load_balance_hosts=round-robin` distributes new connections evenly across healthy nodes.

### Option B: HAProxy / Load Balancer Health Checking
In a production deployment, HAProxy or an AWS ALB / Cloudflare TCP proxy can sit in front of the nodes:

```haproxy
frontend postgres_cluster
    bind *:5000
    mode tcp
    default_backend pg_backends

backend pg_backends
    mode tcp
    balance roundrobin
    option httpchk GET /healthz
    server node-a 192.168.1.10:5432 check port 8008
    server node-b 192.168.1.11:5432 check port 8008
```

---

## 3. Split-Brain Mitigation

In an Active-Active network partition (both nodes survive, but cannot talk to each other):
1. **Isolated Writes**: Clients in Region A write to Node A; clients in Region B write to Node B.
2. **Replication Slots Buffer WAL**: Each node saves changes in its local replication slot (`wal_keep_size`).
3. **Partition Resolution**: Once the network link recovers, both nodes exchange accumulated changes.
4. **Conflict Avoidance**: Because primary keys use `gen_random_uuid()`, inserts will **never** collide.
5. **Updates**: In the rare case of concurrent updates to the same row, the reconciliation engine detects the conflict based on `track_commit_timestamp` and `updated_at`.

---

## 4. Testing Failover

You can test failover and automatic catch-up using the included automated script:

```bash
./scripts/failover-test.sh
```

### Steps Executed by the Test:
1. Shuts down Node A (`docker compose stop node-a`).
2. Sends new transactions to Node B (verifying uninterrupted writes).
3. Restarts Node A (`docker compose start node-a`).
4. Verifies that Node A automatically replays the WAL from Node B and synchronizes the missed data.
