-- ==============================================================================
-- Find Missing Records in Node B (Records existing on Node A but absent in Node B)
-- ==============================================================================
-- Note: This query uses postgres_fdw foreign tables when executed inside Node B.
-- Ensure remote_server_a and foreign tables remote_users / remote_orders are mapped.

-- 1. Missing Users in Node B
SELECT
    a.id,
    a.username,
    a.email,
    a.node_origin,
    a.version,
    a.created_at,
    a.updated_at,
    'MISSING_IN_NODE_B' AS anomaly_type
FROM remote_users a
LEFT JOIN users b ON b.id = a.id
WHERE b.id IS NULL
ORDER BY a.created_at;

-- 2. Missing Orders in Node B
SELECT
    a.id,
    a.order_number,
    a.user_id,
    a.total_amount,
    a.status,
    a.node_origin,
    a.created_at,
    'MISSING_IN_NODE_B' AS anomaly_type
FROM remote_orders a
LEFT JOIN orders b ON b.id = a.id
WHERE b.id IS NULL
ORDER BY a.created_at;

-- 3. Conflicting / Drifted User Records (Differing Versions or Timestamps)
SELECT
    b.id,
    b.username,
    a.version AS node_a_version,
    b.version AS node_b_version,
    a.updated_at AS node_a_updated,
    b.updated_at AS node_b_updated,
    CASE
        WHEN b.updated_at > a.updated_at THEN 'NODE_B_NEWER'
        WHEN a.updated_at > b.updated_at THEN 'NODE_A_NEWER'
        ELSE 'IDENTICAL_TIMESTAMP_DIFFERENT_DATA'
    END AS conflict_resolution_advice
FROM users b
INNER JOIN remote_users a ON a.id = b.id
WHERE a.version != b.version OR a.updated_at != b.updated_at;

-- ==============================================================================
-- 4. Auto-Reconcile ONLY Missing Data into Node B (Strictly Zero Duplicate Data)
-- ==============================================================================

-- 4.1 Reconcile Users (ON CONFLICT DO NOTHING ensures no duplicates)
INSERT INTO users (id, username, email, full_name, role, is_active, node_origin, version, created_at, updated_at)
SELECT a.id, a.username, a.email, a.full_name, a.role, a.is_active, a.node_origin, a.version, a.created_at, a.updated_at
FROM remote_users a
LEFT JOIN users b ON b.id = a.id
WHERE b.id IS NULL
ON CONFLICT (id) DO NOTHING;

-- 4.2 Reconcile Orders (ON CONFLICT DO NOTHING ensures no duplicates)
INSERT INTO orders (id, order_number, user_id, total_amount, currency, status, shipping_address, node_origin, version, created_at, updated_at)
SELECT a.id, a.order_number, a.user_id, a.total_amount, a.currency, a.status, a.shipping_address, a.node_origin, a.version, a.created_at, a.updated_at
FROM remote_orders a
LEFT JOIN orders b ON b.id = a.id
WHERE b.id IS NULL
ON CONFLICT (id) DO NOTHING;

-- 4.3 Reconcile Order Items (ON CONFLICT DO NOTHING ensures no duplicates)
INSERT INTO order_items (id, order_id, product_name, quantity, unit_price, created_at)
SELECT a.id, a.order_id, a.product_name, a.quantity, a.unit_price, a.created_at
FROM remote_order_items a
LEFT JOIN order_items b ON b.id = a.id
WHERE b.id IS NULL
ON CONFLICT (id) DO NOTHING;
