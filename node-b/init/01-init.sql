-- ==============================================================================
-- Node B Initialization - 01-init.sql
-- ==============================================================================

-- Configure Node B identity defaults for incoming writes
ALTER TABLE IF EXISTS users ALTER COLUMN node_origin SET DEFAULT 'node-b';
ALTER TABLE IF EXISTS orders ALTER COLUMN node_origin SET DEFAULT 'node-b';

-- Create an audit table for replication events and cluster logs
CREATE TABLE IF NOT EXISTS cluster_node_info (
    node_name VARCHAR(50) PRIMARY KEY,
    initialized_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    last_heartbeat TIMESTAMPTZ DEFAULT clock_timestamp(),
    status VARCHAR(20) DEFAULT 'ACTIVE'
);

INSERT INTO cluster_node_info (node_name, status)
VALUES ('node-b', 'ACTIVE')
ON CONFLICT (node_name) DO UPDATE SET last_heartbeat = clock_timestamp(), status = 'ACTIVE';
