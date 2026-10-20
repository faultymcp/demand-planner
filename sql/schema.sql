-- Demand planner database: tables linked by keys, the way an ERP stores data.
-- Real data: products, sales. Simulated: sites, suppliers, lead times, stock on hand.
-- Safe to re-run: drops and recreates every table.

DROP TABLE IF EXISTS stock_on_hand, forecasts, sales, product_supplier, suppliers, sites, products CASCADE;

-- One row per product (real)
CREATE TABLE products (
    stock_code   TEXT PRIMARY KEY,
    description  TEXT,
    demand_group TEXT
);

-- One row per site (simulated)
CREATE TABLE sites (
    site_id      INTEGER PRIMARY KEY,
    site_name    TEXT NOT NULL,
    is_simulated BOOLEAN NOT NULL DEFAULT TRUE
);

-- One row per supplier (simulated)
CREATE TABLE suppliers (
    supplier_id     INTEGER PRIMARY KEY,
    supplier_name   TEXT NOT NULL,
    lead_time_weeks INTEGER NOT NULL CHECK (lead_time_weeks > 0),
    is_simulated    BOOLEAN NOT NULL DEFAULT TRUE
);

-- Which supplier each product comes from (simulated)
CREATE TABLE product_supplier (
    stock_code  TEXT PRIMARY KEY REFERENCES products(stock_code),
    supplier_id INTEGER NOT NULL REFERENCES suppliers(supplier_id)
);

-- One row per product line on an invoice (real, with a simulated site)
CREATE TABLE sales (
    sale_id      BIGSERIAL PRIMARY KEY,
    invoice      TEXT NOT NULL,
    stock_code   TEXT NOT NULL REFERENCES products(stock_code),
    site_id      INTEGER NOT NULL REFERENCES sites(site_id),
    quantity     INTEGER NOT NULL,
    price        NUMERIC NOT NULL,
    invoice_date TIMESTAMP NOT NULL,
    customer_id  TEXT,
    country      TEXT
);
CREATE INDEX idx_sales_stock_code   ON sales (stock_code);
CREATE INDEX idx_sales_invoice_date ON sales (invoice_date);

-- Latest forecast per product (TSB, alpha = beta = 0.2)
CREATE TABLE forecasts (
    stock_code            TEXT PRIMARY KEY REFERENCES products(stock_code),
    method                TEXT NOT NULL,
    forecast_week         DATE NOT NULL,
    weekly_forecast       NUMERIC NOT NULL,
    error_sd              NUMERIC NOT NULL,
    prob_of_sale          NUMERIC,
    weeks_since_last_sale INTEGER
);

-- Current stock per product per site (simulated)
CREATE TABLE stock_on_hand (
    stock_code   TEXT    REFERENCES products(stock_code),
    site_id      INTEGER REFERENCES sites(site_id),
    as_of_date   DATE    NOT NULL,
    qty_on_hand  INTEGER NOT NULL CHECK (qty_on_hand >= 0),
    is_simulated BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (stock_code, site_id)
);