-- ==============================================================================
-- Node A Replication & Monitoring User - 03-replication-user.sql
-- ==============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN ENCRYPTED PASSWORD 'replicator_secure_pw_123';
        RAISE NOTICE 'Role replicator created.';
    ELSE
        ALTER ROLE replicator WITH REPLICATION LOGIN ENCRYPTED PASSWORD 'replicator_secure_pw_123';
        RAISE NOTICE 'Role replicator updated.';
    END IF;
END
$$;

-- Grant permissions for replication and schema access
GRANT CONNECT ON DATABASE appdb TO replicator;
GRANT USAGE ON SCHEMA public TO replicator;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO replicator;

-- Grant pg_monitor for prometheus postgres_exporter metrics
GRANT pg_monitor TO replicator;
GRANT pg_read_all_stats TO replicator;
