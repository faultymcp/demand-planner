"""Load the cleaned data, forecasts and simulated ERP tables into PostgreSQL.

Run after the notebook has written data/clean.parquet, data/weekly.parquet
and data/profile.parquet:   python load_database.py
"""
from getpass import getpass
from pathlib import Path

import numpy as np
import pandas as pd
from sqlalchemy import URL, create_engine

PROJECT = Path(__file__).resolve().parent
DATA = PROJECT / "data"
rng = np.random.default_rng(42)          # fixed seed, so the simulated data is the same every run


def tsb(y, alpha=0.2, beta=0.2):
    """TSB forecast. Returns (forecasts before each week, next-week forecast, final probability)."""
    y = np.asarray(y, dtype=float)
    f = np.full(len(y), np.nan)
    z = p = None
    q = 1
    for t, d in enumerate(y):
        if z is not None:
            f[t] = p * z
        if z is None:
            if d > 0:
                z, p = d, 1 / q
            else:
                q += 1
            continue
        if d > 0:
            p += beta * (1 - p)
            z += alpha * (d - z)
        else:
            p += beta * (0 - p)
    if z is None:
        return f, 0.0, 0.0
    return f, p * z, p


# ---------- 1. Read the notebook's outputs ----------
clean = pd.read_parquet(DATA / "clean.parquet")
weekly = pd.read_parquet(DATA / "weekly.parquet").sort_values(["StockCode", "week"])
profile = pd.read_parquet(DATA / "profile.parquet")

# ---------- 2. Products (real) ----------
# The same code can have several descriptions, so keep the most common one.
desc = (clean.groupby(["StockCode", "Description"]).size()
        .reset_index(name="n")
        .sort_values("n", ascending=False)
        .drop_duplicates("StockCode"))
products = pd.DataFrame({"stock_code": desc["StockCode"].astype(str),
                         "description": desc["Description"].astype(str)})
products["demand_group"] = products["stock_code"].map(profile["group"])

# ---------- 3. Sites and suppliers (simulated) ----------
sites = pd.DataFrame({"site_id": [1, 2, 3],
                      "site_name": ["Site A (simulated)", "Site B (simulated)", "Site C (simulated)"]})

n_suppliers = 8
suppliers = pd.DataFrame({
    "supplier_id": range(1, n_suppliers + 1),
    "supplier_name": [f"Supplier {i} (simulated)" for i in range(1, n_suppliers + 1)],
    "lead_time_weeks": rng.integers(1, 7, size=n_suppliers),       # 1 to 6 weeks
})
product_supplier = pd.DataFrame({
    "stock_code": products["stock_code"],
    "supplier_id": rng.integers(1, n_suppliers + 1, size=len(products)),
})

# ---------- 4. Sales (real), each invoice assigned to one simulated site ----------
invoice = clean["Invoice"].astype(str)
unique_invoices = invoice.unique()
invoice_site = pd.Series(rng.choice([1, 2, 3], size=len(unique_invoices), p=[0.6, 0.3, 0.1]),
                         index=unique_invoices)
customer = clean["Customer ID"].astype(object)
sales = pd.DataFrame({
    "invoice": invoice,
    "stock_code": clean["StockCode"].astype(str),
    "site_id": invoice.map(invoice_site).astype(int),
    "quantity": clean["Quantity"].astype(int),
    "price": clean["Price"].astype(float),
    "invoice_date": clean["InvoiceDate"],
    "customer_id": customer.where(clean["Customer ID"].notna(), None),
    "country": clean["Country"].astype(object),
})

# ---------- 5. Forecasts (TSB, alpha = beta = 0.2, using all history) ----------
forecast_week = (weekly["week"].max() + pd.Timedelta(weeks=1)).date()
rows = []
for code, g in weekly.groupby("StockCode"):
    y = g["qty"].to_numpy(dtype=float)
    f, next_week, prob = tsb(y)
    err = (f - y)[~np.isnan(f)]
    sales_weeks = np.flatnonzero(y > 0)
    rows.append({
        "stock_code": str(code),
        "method": "TSB alpha=0.2 beta=0.2",
        "forecast_week": forecast_week,
        "weekly_forecast": float(next_week),
        "error_sd": float(err.std()) if len(err) > 1 else 0.0,
        "prob_of_sale": float(prob),
        "weeks_since_last_sale": int(len(y) - 1 - sales_weeks[-1]) if len(sales_weeks) else None,
        "avg_weekly": float(y.mean()),          # used only to simulate stock below
    })
forecasts = pd.DataFrame(rows)

# ---------- 6. Stock on hand (simulated) ----------
# Each site's share of a product's sales, then stock = past average demand x share x random cover.
# Basing it on PAST demand means discontinued products still hold stock, as they would in reality.
net = sales.groupby(["stock_code", "site_id"])["quantity"].sum().clip(lower=0)
share = (net / net.groupby(level=0).transform("sum")).fillna(0).rename("share").reset_index()
stock = share.merge(forecasts[["stock_code", "avg_weekly"]], on="stock_code")
stock["qty_on_hand"] = np.round(stock["avg_weekly"] * stock["share"]
                                * rng.uniform(0, 6, size=len(stock))).astype(int)
stock["as_of_date"] = forecast_week
stock_on_hand = stock[["stock_code", "site_id", "as_of_date", "qty_on_hand"]]

forecasts = forecasts.drop(columns="avg_weekly")

# ---------- 7. Write everything to PostgreSQL ----------
password = getpass("PostgreSQL password for user 'postgres': ")   # never hard-code passwords
engine = create_engine(URL.create("postgresql+psycopg2", username="postgres", password=password,
                                  host="localhost", port=5432, database="demand_planner"))

schema_sql = (PROJECT / "sql" / "schema.sql").read_text()
with engine.begin() as conn:                                   # one transaction: all or nothing
    conn.exec_driver_sql(schema_sql)
    # Parent tables first, because child tables point at them (foreign keys)
    for name, table in [("products", products), ("sites", sites), ("suppliers", suppliers),
                        ("product_supplier", product_supplier), ("sales", sales),
                        ("forecasts", forecasts), ("stock_on_hand", stock_on_hand)]:
        print(f"Loading {name}: {len(table):,} rows")
        table.to_sql(name, conn, if_exists="append", index=False, method="multi", chunksize=5000)

print("Done.")
