# Logical Replication Guide: Bidirectional Active-Active

## 1. Principles of Operation

Logical replication uses a **publish and subscribe** model based on decoding WAL (Write-Ahead Logging) changes into logical SQL-like operations (inserts, updates, deletes) rather than physical block-level copying.

### Key Features Used:
- **`wal_level = logical`**: Instructs the PostgreSQL server to retain full decoded tuple descriptions in the WAL stream.
- **`track_commit_timestamp = on`**: Allows PostgreSQL to track the precise commit timestamp for every transaction.
- **`CREATE PUBLICATION pub_node FOR ALL TABLES`**: Publishes mutations for all current and future tables in the database.
- **`CREATE SUBSCRIPTION ... WITH (origin = 'none')`**: Subscribes to the remote publication while ignoring changes that originated from another replica.

---

## 2. Publication Setup

On each node, publications are declared during database initialization:

```sql
-- On Node A:
CREATE PUBLICATION pub_node_a FOR ALL TABLES;

-- On Node B:
CREATE PUBLICATION pub_node_b FOR ALL TABLES;
```

To verify active publications:
```sql
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete FROM pg_publication;
```

---

## 3. Subscription Setup

Once both databases have initialized and network connectivity is verified:

```sql
-- On Node A (subscribing to Node B):
CREATE SUBSCRIPTION sub_node_b_to_a
    CONNECTION 'host=node-b port=5432 dbname=appdb user=replicator password=replicator_secure_pw_123'
    PUBLICATION pub_node_b
    WITH (copy_data = false, create_slot = true, origin = 'none');

-- On Node B (subscribing to Node A):
CREATE SUBSCRIPTION sub_node_a_to_b
    CONNECTION 'host=node-a port=5432 dbname=appdb user=replicator password=replicator_secure_pw_123'
    PUBLICATION pub_node_a
    WITH (copy_data = false, create_slot = true, origin = 'none');
```

> **Why `copy_data = false`?**
> When bootstrapping an empty cluster where schemas are initialized identically on both nodes, setting `copy_data = false` avoids double-copy conflicts during initial connection. If migrating existing data from an active node to a new replica, set `copy_data = true` on the new replica only.

---

## 4. Monitoring Replication Health

### Checking Publisher Activity (`pg_stat_replication`)
Run on the publisher node:
```sql
SELECT
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

### Checking Subscriber Activity (`pg_stat_subscription`)
Run on the subscriber node:
```sql
SELECT
    subname,
    pid,
    received_lsn,
    last_msg_receipt_time,
    latest_end_lsn
FROM pg_stat_subscription;
```

### Checking Replication Slots (`pg_replication_slots`)
Replication slots guarantee that the publisher does not delete WAL segments before the subscriber has consumed them:
```sql
SELECT
    slot_name,
    plugin,
    active,
    wal_status,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retain_bytes
FROM pg_replication_slots;
```

---

## 5. Troubleshooting Replication Issues

### Inactive Replication Slot
If `active` is `false` in `pg_replication_slots`:
1. Check the subscriber database container logs: `docker compose logs -f node-a` or `node-b`.
2. Verify authentication credentials in `node-a/.env` and `node-b/.env`.
3. Check network reachability with `pg_isready`.

### Subscription Worker Error / Halt
If a conflict occurs (e.g., unique key violation), the logical replication worker halts to prevent data divergence.
To inspect the error:
```sql
SELECT * FROM pg_stat_subscription WHERE pid IS NULL;
```
Check container logs for error details:
```bash
docker compose logs node-a --tail=50
```
To skip a problematic transaction LSN if necessary:
```sql
ALTER SUBSCRIPTION sub_node_b_to_a SKIP (lsn = '0/16B2D40');
```
