-- ==============================================================================
-- Node A Logical Replication Publication - 02-publication.sql
-- ==============================================================================

-- Create publication for all tables in the database
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'pub_node_a'
    ) THEN
        CREATE PUBLICATION pub_node_a FOR ALL TABLES;
        RAISE NOTICE 'Publication pub_node_a created successfully.';
    ELSE
        RAISE NOTICE 'Publication pub_node_a already exists.';
    END IF;
END
$$;
