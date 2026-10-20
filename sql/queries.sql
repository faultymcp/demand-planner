-- Run these in pgAdmin's Query Tool or psql, one at a time.

-- 1. Check the load: row counts per table
SELECT 'products' AS table_name, COUNT(*) FROM products
UNION ALL SELECT 'sites', COUNT(*) FROM sites
UNION ALL SELECT 'suppliers', COUNT(*) FROM suppliers
UNION ALL SELECT 'product_supplier', COUNT(*) FROM product_supplier
UNION ALL SELECT 'sales', COUNT(*) FROM sales
UNION ALL SELECT 'forecasts', COUNT(*) FROM forecasts
UNION ALL SELECT 'stock_on_hand', COUNT(*) FROM stock_on_hand;

-- 2. Best-selling products at each site (a join plus a window function)
WITH site_sales AS (
    SELECT s.site_name, p.stock_code, p.description, SUM(sa.quantity) AS units
    FROM sales sa
    JOIN products p ON p.stock_code = sa.stock_code
    JOIN sites s    ON s.site_id = sa.site_id
    GROUP BY s.site_name, p.stock_code, p.description
)
SELECT *
FROM (
    SELECT *, RANK() OVER (PARTITION BY site_name ORDER BY units DESC) AS rank_at_site
    FROM site_sales
) ranked
WHERE rank_at_site <= 5
ORDER BY site_name, rank_at_site;

-- 3. Reorder list: products below their reorder level at each site, how much to order, and which supplier to call.
--    reorder level = forecast x site share x (lead time + 1) + safety stock
WITH site_units AS (
    SELECT stock_code, site_id, GREATEST(SUM(quantity), 0)::numeric AS units
    FROM sales
    GROUP BY stock_code, site_id
),
shares AS (
    SELECT stock_code, site_id,
           units / NULLIF(SUM(units) OVER (PARTITION BY stock_code), 0) AS share
    FROM site_units
),
levels AS (
    SELECT soh.stock_code, soh.site_id, soh.qty_on_hand,
           sup.supplier_name, sup.lead_time_weeks,
           (f.weekly_forecast * sh.share * (sup.lead_time_weeks + 1)
            + 1.65 * f.error_sd * sh.share * SQRT(sup.lead_time_weeks + 1))::numeric AS reorder_level
    FROM stock_on_hand soh
    JOIN shares sh           ON sh.stock_code = soh.stock_code AND sh.site_id = soh.site_id
    JOIN forecasts f         ON f.stock_code = soh.stock_code
    JOIN product_supplier ps ON ps.stock_code = soh.stock_code
    JOIN suppliers sup       ON sup.supplier_id = ps.supplier_id
)
SELECT s.site_name, l.stock_code, p.description,
       l.qty_on_hand,
       ROUND(l.reorder_level, 1)             AS reorder_level,
       CEIL(l.reorder_level - l.qty_on_hand) AS suggested_order,
       l.supplier_name, l.lead_time_weeks
FROM levels l
JOIN products p ON p.stock_code = l.stock_code
JOIN sites s    ON s.site_id = l.site_id
WHERE l.qty_on_hand < l.reorder_level
ORDER BY suggested_order DESC
LIMIT 50;

-- 4. End-of-life candidates: products that have stopped selling but still hold stock.
WITH avg_price AS (
    SELECT stock_code, AVG(price) AS avg_price
    FROM sales WHERE quantity > 0 GROUP BY stock_code
)
SELECT p.stock_code, p.description,
       f.weeks_since_last_sale,
       ROUND(f.prob_of_sale, 3)                      AS prob_of_sale,
       SUM(soh.qty_on_hand)                          AS units_on_hand,
       ROUND(SUM(soh.qty_on_hand) * ap.avg_price, 2) AS stock_value_gbp
FROM forecasts f
JOIN products p        ON p.stock_code = f.stock_code
JOIN stock_on_hand soh ON soh.stock_code = f.stock_code
JOIN avg_price ap      ON ap.stock_code = f.stock_code
WHERE f.prob_of_sale < 0.2 AND f.weeks_since_last_sale >= 8
GROUP BY p.stock_code, p.description, f.weeks_since_last_sale, f.prob_of_sale, ap.avg_price
HAVING SUM(soh.qty_on_hand) > 0
ORDER BY stock_value_gbp DESC
LIMIT 30;

-- 5. Total value of simulated stock sitting on end-of-life products
WITH avg_price AS (
    SELECT stock_code, AVG(price) AS avg_price FROM sales WHERE quantity > 0 GROUP BY stock_code
)
SELECT COUNT(DISTINCT f.stock_code)                  AS products,
       SUM(soh.qty_on_hand)                          AS units,
       ROUND(SUM(soh.qty_on_hand * ap.avg_price), 2) AS stock_value_gbp
FROM forecasts f
JOIN stock_on_hand soh ON soh.stock_code = f.stock_code
JOIN avg_price ap      ON ap.stock_code = f.stock_code
WHERE f.prob_of_sale < 0.2 AND f.weeks_since_last_sale >= 8;