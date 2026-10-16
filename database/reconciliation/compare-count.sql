-- ==============================================================================
-- Database Parity & Checksum Verification Query
-- ==============================================================================

WITH user_stats AS (
    SELECT
        'users' AS table_name,
        count(*) AS total_rows,
        max(updated_at) AS last_updated,
        coalesce(md5(string_agg(id::text || ':' || version::text, ',' ORDER BY id)), 'EMPTY') AS table_checksum
    FROM users
),
order_stats AS (
    SELECT
        'orders' AS table_name,
        count(*) AS total_rows,
        max(updated_at) AS last_updated,
        coalesce(md5(string_agg(id::text || ':' || version::text, ',' ORDER BY id)), 'EMPTY') AS table_checksum
    FROM orders
),
item_stats AS (
    SELECT
        'order_items' AS table_name,
        count(*) AS total_rows,
        max(created_at) AS last_updated,
        coalesce(md5(string_agg(id::text || ':' || quantity::text, ',' ORDER BY id)), 'EMPTY') AS table_checksum
    FROM order_items
)
SELECT * FROM user_stats
UNION ALL
SELECT * FROM order_stats
UNION ALL
SELECT * FROM item_stats;
