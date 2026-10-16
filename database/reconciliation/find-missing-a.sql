-- ==============================================================================
-- Find Missing Records in Node A (Records existing on Node B but absent in Node A)
-- ==============================================================================
-- Note: This query uses postgres_fdw foreign tables when executed inside Node A.
-- Ensure remote_server_b and foreign tables remote_users / remote_orders are mapped.

-- 1. Missing Users in Node A
SELECT
    b.id,
    b.username,
    b.email,
    b.node_origin,
    b.version,
    b.created_at,
    b.updated_at,
    'MISSING_IN_NODE_A' AS anomaly_type
FROM remote_users b
LEFT JOIN users a ON a.id = b.id
WHERE a.id IS NULL
ORDER BY b.created_at;

-- 2. Missing Orders in Node A
SELECT
    b.id,
    b.order_number,
    b.user_id,
    b.total_amount,
    b.status,
    b.node_origin,
    b.created_at,
    'MISSING_IN_NODE_A' AS anomaly_type
FROM remote_orders b
LEFT JOIN orders a ON a.id = b.id
WHERE a.id IS NULL
ORDER BY b.created_at;

-- 3. Conflicting / Drifted User Records (Differing Versions or Timestamps)
SELECT
    a.id,
    a.username,
    a.version AS node_a_version,
    b.version AS node_b_version,
    a.updated_at AS node_a_updated,
    b.updated_at AS node_b_updated,
    CASE
        WHEN a.updated_at > b.updated_at THEN 'NODE_A_NEWER'
        WHEN b.updated_at > a.updated_at THEN 'NODE_B_NEWER'
        ELSE 'IDENTICAL_TIMESTAMP_DIFFERENT_DATA'
    END AS conflict_resolution_advice
FROM users a
INNER JOIN remote_users b ON a.id = b.id
WHERE a.version != b.version OR a.updated_at != b.updated_at;

-- ==============================================================================
-- 4. Auto-Reconcile ONLY Missing Data into Node A (Strictly Zero Duplicate Data)
-- ==============================================================================

-- 4.1 Reconcile Users (ON CONFLICT DO NOTHING ensures no duplicates)
INSERT INTO users (id, username, email, full_name, role, is_active, node_origin, version, created_at, updated_at)
SELECT b.id, b.username, b.email, b.full_name, b.role, b.is_active, b.node_origin, b.version, b.created_at, b.updated_at
FROM remote_users b
LEFT JOIN users a ON a.id = b.id
WHERE a.id IS NULL
ON CONFLICT (id) DO NOTHING;

-- 4.2 Reconcile Orders (ON CONFLICT DO NOTHING ensures no duplicates)
INSERT INTO orders (id, order_number, user_id, total_amount, currency, status, shipping_address, node_origin, version, created_at, updated_at)
SELECT b.id, b.order_number, b.user_id, b.total_amount, b.currency, b.status, b.shipping_address, b.node_origin, b.version, b.created_at, b.updated_at
FROM remote_orders b
LEFT JOIN orders a ON a.id = b.id
WHERE a.id IS NULL
ON CONFLICT (id) DO NOTHING;

-- 4.3 Reconcile Order Items (ON CONFLICT DO NOTHING ensures no duplicates)
INSERT INTO order_items (id, order_id, product_name, quantity, unit_price, created_at)
SELECT b.id, b.order_id, b.product_name, b.quantity, b.unit_price, b.created_at
FROM remote_order_items b
LEFT JOIN order_items a ON a.id = b.id
WHERE a.id IS NULL
ON CONFLICT (id) DO NOTHING;
