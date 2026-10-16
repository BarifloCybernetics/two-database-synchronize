# Disaster Recovery & Backup Runbook

## 1. Objectives & Metrics

- **Recovery Point Objective (RPO)**: Near 0 (sub-second) under normal operation via asynchronous logical replication; <= 24 hours from cold backups.
- **Recovery Time Objective (RTO)**:
  - Single node failure: **0 seconds** (instantaneous client redirect to surviving node).
  - Complete dual-node failure: **< 15 minutes** (restoration from verified gzip backups).

---

## 2. Backup Strategy

Automated backup scripts are located in `backup/node-a/` and `backup/node-b/`:

### Taking an Immediate Backup
```bash
# Backup Node A:
./backup/node-a/backup.sh

# Backup Node B:
./backup/node-b/backup.sh
```

### Characteristics:
- Compressed with `gzip` to minimize storage consumption.
- Generates a companion `.sha256` checksum to ensure archive integrity.
- Enforces an automated retention policy (default: 7 days).

---

## 3. Disaster Scenarios & Recovery Runbooks

### Scenario A: Single Node Loss (Rebuilding Node B from Node A)

If Node B suffers catastrophic disk loss:

1. Stop Node B container:
   ```bash
   docker compose stop node-b
   docker volume rm postgres-active-active_node-b-data
   ```

2. Start a fresh Node B container:
   ```bash
   docker compose up -d node-b
   ```

3. Re-synchronize data from Node A to Node B:
   ```bash
   # Dump data from surviving Node A into new Node B
   docker exec -i postgres-node-a pg_dump -U postgres -d appdb --clean | \
   docker exec -i postgres-node-b psql -U postgres -d appdb
   ```

4. Re-establish bidirectional subscriptions:
   ```bash
   ./scripts/setup-replication.sh
   ```

5. Verify sync status:
   ```bash
   ./scripts/status.sh
   ```

---

### Scenario B: Total Cluster Outage (Cold Restore)

If both Node A and Node B are lost:

1. Start fresh cluster containers:
   ```bash
   ./scripts/start.sh
   ```

2. Restore the latest verified backup into Node A:
   ```bash
   ./backup/node-a/restore.sh
   ```

3. Replicate or dump to Node B:
   ```bash
   ./database/reconciliation/reconcile.sh --fix
   ```

4. Confirm health with status check:
   ```bash
   ./scripts/status.sh
   ```
