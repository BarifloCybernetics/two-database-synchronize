-- ==============================================================================
-- Schema: 001 - Users Table & Base Extensions
-- ==============================================================================

-- Extensions needed for UUID generation, FDW cross-node queries, and metrics
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "postgres_fdw";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Function: update timestamp and increment row version
CREATE OR REPLACE FUNCTION update_timestamp_and_version()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = clock_timestamp();
    NEW.version = OLD.version + 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Users Table
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    full_name VARCHAR(100),
    role VARCHAR(20) NOT NULL DEFAULT 'customer' CHECK (role IN ('admin', 'manager', 'customer', 'support')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    node_origin VARCHAR(20) NOT NULL DEFAULT 'unknown',
    version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- REPLICA IDENTITY FULL ensures logical replication can match old and new row values during UPDATE/DELETE
ALTER TABLE users REPLICA IDENTITY FULL;

-- Trigger for version and timestamp
DROP TRIGGER IF EXISTS trg_users_timestamp ON users;
CREATE TRIGGER trg_users_timestamp
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_timestamp_and_version();
