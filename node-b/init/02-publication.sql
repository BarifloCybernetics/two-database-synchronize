-- ==============================================================================
-- Node B Logical Replication Publication - 02-publication.sql
-- ==============================================================================

-- Create publication for all tables in the database
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'pub_node_b'
    ) THEN
        CREATE PUBLICATION pub_node_b FOR ALL TABLES;
        RAISE NOTICE 'Publication pub_node_b created successfully.';
    ELSE
        RAISE NOTICE 'Publication pub_node_b already exists.';
    END IF;
END
$$;
