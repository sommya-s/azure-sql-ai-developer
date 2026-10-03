#!/usr/bin/env python3
"""Trailhead Outfitters synthetic data generator.

One deterministic dataset feeds all three tracks:

* DP-800  -> a clean T-SQL seed script for the operational database
             (sql/02_seed_data.sql)
* DP-700  -> "landing zone" files with realistic problems (duplicates, nulls,
             bad formats, late-arriving rows, schema-shaped variety: CSV,
             JSON Lines, JSON arrays) to upload into a Lakehouse Files area
* DP-600  -> consumes what DP-700 builds; answer keys let you check your
             gold-layer numbers

Only the Python standard library is needed.

Usage
-----
    python generate_data.py                       # defaults, writes ./output
    python generate_data.py --days 28 --seed 42 --start-date 2026-08-01
    python generate_data.py --sql-seed ../sql/02_seed_data.sql
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import random
from collections import Counter, defaultdict
from pathlib import Path

import catalog_text as T

REGIONS = {
    "Baltics": {"Latvia": ["Riga", "Daugavpils", "Liepaja"],
                "Lithuania": ["Vilnius", "Kaunas"],
                "Estonia": ["Tallinn", "Tartu"]},
    "Nordics": {"Finland": ["Helsinki", "Tampere"],
                "Sweden": ["Stockholm", "Gothenburg"],
                "Norway": ["Oslo", "Bergen"]},
    "Central Europe": {"Germany": ["Berlin", "Munich"],
                       "Poland": ["Warsaw", "Krakow"],
                       "Austria": ["Vienna", "Innsbruck"]},
}
COUNTRY_REGION = {c: r for r, cs in REGIONS.items() for c in cs}
PHONE_PREFIX = {"Latvia": "+371", "Lithuania": "+370", "Estonia": "+372", "Finland": "+358",
                "Sweden": "+46", "Norway": "+47", "Germany": "+49", "Poland": "+48", "Austria": "+43"}

STORES = [  # StoreID, StoreCode, StoreName, City, Country, OpenedOn
    (1, "RIX01", "Trailhead Riga Old Town", "Riga", "Latvia", "2019-04-12"),
    (2, "RIX02", "Trailhead Riga Spice", "Riga", "Latvia", "2021-09-01"),
    (3, "VNO01", "Trailhead Vilnius", "Vilnius", "Lithuania", "2020-03-15"),
    (4, "TLL01", "Trailhead Tallinn", "Tallinn", "Estonia", "2020-06-20"),
    (5, "HEL01", "Trailhead Helsinki", "Helsinki", "Finland", "2021-02-10"),
    (6, "STO01", "Trailhead Stockholm", "Stockholm", "Sweden", "2022-05-05"),
    (7, "OSL01", "Trailhead Oslo", "Oslo", "Norway", "2022-11-18"),
    (8, "BER01", "Trailhead Berlin", "Berlin", "Germany", "2023-03-01"),
    (9, "MUC01", "Trailhead Munich", "Munich", "Germany", "2023-08-24"),
    (10, "WAW01", "Trailhead Warsaw", "Warsaw", "Poland", "2024-01-15"),
    (11, "KRK01", "Trailhead Krakow", "Krakow", "Poland", "2024-06-01"),
    (12, "INN01", "Trailhead Innsbruck", "Innsbruck", "Austria", "2025-04-04"),
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="output", help="output folder (default: ./output)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--start-date", default="2026-08-01", help="first business day (YYYY-MM-DD)")
    p.add_argument("--days", type=int, default=28, help="number of daily incremental batches")
    p.add_argument("--customers", type=int, default=1200)
    p.add_argument("--products", type=int, default=240)
    p.add_argument("--orders-per-day", type=int, default=140)
    p.add_argument("--sql-seed", default=None,
                   help="also write a T-SQL seed script for the DP-800 database to this path")
    return p.parse_args()


# --------------------------------------------------------------------------------------
# Builders for each entity
# --------------------------------------------------------------------------------------

def build_products(rng: random.Random, n: int) -> list[dict]:
    products = []
    used_names = set()
    for pid in range(1, n + 1):
        cat = T.CATEGORIES[(pid - 1) % len(T.CATEGORIES)]
        cat_id, cat_name, _dept, noun, (pmin, pmax) = cat
        while True:
            brand = rng.choice(T.BRANDS)
            name = f"{brand} {rng.choice(T.MODEL_WORDS)}{rng.choice(T.MODEL_SUFFIX)} {noun}"
            if name not in used_names:
                used_names.add(name)
                break
        price = round(rng.uniform(pmin, pmax) / 5) * 5 - 0.01
        cost = round(price * rng.uniform(0.38, 0.62), 2)
        features = rng.sample(T.DESCRIPTION_FEATURES[cat_id], k=min(3, len(T.DESCRIPTION_FEATURES[cat_id])))
        article = "an" if noun[0].lower() in "aeiou" else "a"
        description = (f"The {name} is {article} {noun.lower()} built for {rng.choice(['day hikes', 'multi-day treks', 'alpine routes', 'family camping', 'fast and light adventures', 'Nordic winters'])}. "
                       + " ".join(f[0].upper() + f[1:] + "." for f in features))
        attrs = build_attributes(rng, cat_id, name)
        products.append({
            "ProductID": pid,
            "SKU": f"TH-{cat_id:02d}-{pid:05d}",
            "ProductName": name,
            "CategoryID": cat_id,
            "Brand": brand,
            "ListPrice": round(price, 2),
            "StandardCost": cost,
            "Attributes": attrs,
            "Description": description,
            "IsActive": 1 if rng.random() > 0.04 else 0,
            "Quality": rng.uniform(0.45, 0.95),   # latent: drives review ratings, not exported
        })
    return products


def build_attributes(rng: random.Random, cat_id: int, name: str) -> dict:
    a: dict = {"colors": rng.sample(T.COLORS, k=rng.randint(1, 3)),
               "weight_g": rng.randint(120, 2400)}
    if cat_id in (1, 2, 3):
        a["sizes"] = list(range(36, 48))
        a["waterproof"] = cat_id == 1 or "GTX" in name or rng.random() < 0.2
        a["weight_g"] = rng.randint(600, 1500) if cat_id == 1 else rng.randint(250, 700)
    elif cat_id in (4, 5, 6, 7):
        a["sizes"] = ["XS", "S", "M", "L", "XL", "XXL"]
        a["waterproof"] = cat_id == 4
        a["material"] = rng.choice(["recycled nylon", "polyester ripstop", "merino wool", "down 800 fill", "synthetic insulation"])
    elif cat_id == 8:
        a.update(capacity_persons=rng.choice([1, 2, 3, 4]), season=rng.choice(["3-season", "4-season"]),
                 waterproof=True, weight_g=rng.randint(900, 4200))
    elif cat_id == 9:
        a.update(comfort_temp_c=rng.choice([10, 5, 0, -5, -10, -18]), fill=rng.choice(["down", "synthetic"]))
    elif cat_id == 10:
        a.update(r_value=round(rng.uniform(1.5, 7.2), 1))
    elif cat_id in (12, 13):
        a.update(capacity_l=rng.choice([18, 22, 25, 30]) if cat_id == 12 else rng.choice([45, 55, 60, 65, 70]),
                 waterproof=False)
    elif cat_id == 14:
        a.update(lumens=rng.choice([200, 350, 450, 600, 900, 1200]), battery_h=rng.randint(6, 80),
                 waterproof=rng.random() < 0.7)
    elif cat_id == 15:
        a.update(satellite_messaging=rng.random() < 0.5, battery_h=rng.randint(16, 200))
    elif cat_id == 17:
        a.update(diameter_mm=rng.choice([8.9, 9.2, 9.5, 9.8, 10.2]), length_m=rng.choice([50, 60, 70, 80]),
                 dry_treated=rng.random() < 0.6)
    return a


def build_customers(rng: random.Random, n: int, start: dt.date) -> list[dict]:
    customers = []
    for cid in range(1, n + 1):
        region = rng.choices(list(REGIONS), weights=[0.5, 0.25, 0.25])[0]
        country = rng.choice(list(REGIONS[region]))
        city = rng.choice(REGIONS[region][country])
        first, last = rng.choice(T.FIRST_NAMES), rng.choice(T.LAST_NAMES)
        created = start - dt.timedelta(days=rng.randint(30, 3 * 365))
        customers.append({
            "CustomerID": cid,
            "CustomerCode": f"C{cid:07d}",
            "FirstName": first,
            "LastName": last,
            "Email": f"{first.lower()}.{last.lower()}{cid}@example.com",
            "Phone": f"{PHONE_PREFIX[country]} {rng.randint(2000, 2999)} {rng.randint(1000, 9999)}",
            "City": city,
            "Country": country,
            "LoyaltyTier": rng.choices(["Bronze", "Silver", "Gold"], weights=[0.6, 0.3, 0.1])[0],
            "CreatedAt": dt.datetime.combine(created, dt.time(rng.randint(8, 21), rng.randint(0, 59))),
            "ReferredByCustomerID": rng.randint(1, cid - 1) if cid > 20 and rng.random() < 0.2 else None,
        })
    return customers


def typo(rng: random.Random, s: str) -> str:
    """Introduce one realistic typo (swap, drop, double or replace a letter)."""
    if len(s) < 4:
        return s + s[-1]
    i = rng.randint(1, len(s) - 2)
    kind = rng.choice(["swap", "drop", "double", "replace"])
    if kind == "swap":
        return s[:i] + s[i + 1] + s[i] + s[i + 2:]
    if kind == "drop":
        return s[:i] + s[i + 1:]
    if kind == "double":
        return s[:i] + s[i] + s[i:]
    return s[:i] + rng.choice("aeiouy") + s[i + 1:]


def add_near_duplicates(rng: random.Random, customers: list[dict], k: int = 18) -> list[tuple[int, int]]:
    """Append k near-duplicate customers (typos in names, different email). Returns (original, duplicate) pairs."""
    pairs = []
    next_id = max(c["CustomerID"] for c in customers) + 1
    for orig in rng.sample(customers[:-50], k):
        dup = dict(orig)
        dup["CustomerID"] = next_id
        dup["CustomerCode"] = f"C{next_id:07d}"
        if rng.random() < 0.5:
            dup["FirstName"] = typo(rng, orig["FirstName"])
        else:
            dup["LastName"] = typo(rng, orig["LastName"])
        dup["Email"] = f"{dup['FirstName'].lower()}{rng.randint(1, 99)}@example.org"
        dup["CreatedAt"] = orig["CreatedAt"] + dt.timedelta(days=rng.randint(30, 300))
        dup["ReferredByCustomerID"] = None
        customers.append(dup)
        pairs.append((orig["CustomerID"], next_id))
        next_id += 1
    return pairs


# --------------------------------------------------------------------------------------
# Main simulation
# --------------------------------------------------------------------------------------

def simulate(args: argparse.Namespace) -> dict:
    rng = random.Random(args.seed)
    start = dt.date.fromisoformat(args.start_date)
    end = start + dt.timedelta(days=args.days)

    products = build_products(rng, args.products)
    customers = build_customers(rng, args.customers, start)
    near_dups = add_near_duplicates(rng, customers)
    cust_by_id = {c["CustomerID"]: c for c in customers}
    prod_by_id = {p["ProductID"]: p for p in products}
    stores_by_region = defaultdict(list)
    for s in STORES:
        stores_by_region[COUNTRY_REGION[s[4]]].append(s)

    initial_customer_ids = {c["CustomerID"] for c in customers}
    customer_snapshot_day0 = [dict(c) for c in customers]
    product_snapshot_day0 = [dict(p) for p in products]

    orders, lines, reviews, tickets, events = [], [], [], [], []
    customer_changes: dict[dt.date, list[dict]] = defaultdict(list)   # delta files
    product_changes: dict[dt.date, list[dict]] = defaultdict(list)
    late_customer_ids: set[int] = set()
    order_id = 100000
    review_id = 0
    ticket_id = 0
    next_customer_id = max(cust_by_id) + 1
    active_products = [p for p in products if p["IsActive"]]
    weights = [p["Quality"] + 0.2 for p in active_products]   # better products sell more

    for d in range(args.days):
        day = start + dt.timedelta(days=d)

        # ---- customer changes: moves (SCD2), tier changes (SCD2), email changes (SCD1), new sign-ups
        for c in rng.sample([c for c in customers if c["CustomerID"] in cust_by_id], k=rng.randint(6, 14)):
            change = rng.choice(["move", "tier", "email"])
            if change == "move":
                region = COUNTRY_REGION[c["Country"]]
                c["City"] = rng.choice([x for x in REGIONS[region][c["Country"]] if x != c["City"]] or [c["City"]])
            elif change == "tier":
                c["LoyaltyTier"] = {"Bronze": "Silver", "Silver": "Gold", "Gold": "Silver"}[c["LoyaltyTier"]]
            else:
                c["Email"] = f"{c['FirstName'].lower()}.{c['LastName'].lower()}.{rng.randint(100, 999)}@example.net"
            customer_changes[day].append(dict(c, _change=change))

        new_today = []
        for _ in range(rng.randint(5, 15)):
            region = rng.choices(list(REGIONS), weights=[0.5, 0.25, 0.25])[0]
            country = rng.choice(list(REGIONS[region]))
            first, last = rng.choice(T.FIRST_NAMES), rng.choice(T.LAST_NAMES)
            c = {"CustomerID": next_customer_id, "CustomerCode": f"C{next_customer_id:07d}",
                 "FirstName": first, "LastName": last,
                 "Email": f"{first.lower()}.{last.lower()}{next_customer_id}@example.com",
                 "Phone": f"{PHONE_PREFIX[country]} {rng.randint(2000, 2999)} {rng.randint(1000, 9999)}",
                 "City": rng.choice(REGIONS[region][country]), "Country": country, "LoyaltyTier": "Bronze",
                 "CreatedAt": dt.datetime.combine(day, dt.time(rng.randint(8, 21), rng.randint(0, 59))),
                 "ReferredByCustomerID": rng.choice(list(initial_customer_ids)) if rng.random() < 0.3 else None}
            customers.append(c)
            cust_by_id[c["CustomerID"]] = c
            new_today.append(c)
            next_customer_id += 1
            # 30% of new customers only show up in the NEXT day's delta file -> late-arriving dimension
            if rng.random() < 0.3 and d < args.days - 1:
                late_customer_ids.add(c["CustomerID"])
                customer_changes[day + dt.timedelta(days=1)].append(dict(c, _change="new"))
            else:
                customer_changes[day].append(dict(c, _change="new"))

        # ---- product price changes (handled as SCD1 in the lakehouse, audited in the ledger in SQL)
        if d % 7 == 3:
            for p in rng.sample(active_products, k=6):
                p["ListPrice"] = round(p["ListPrice"] * rng.choice([0.85, 0.9, 1.05, 1.1]), 2)
                p["ListPrice"] = max(p["ListPrice"], round(p["StandardCost"] + 1, 2))
                product_changes[day].append(dict(p))

        # ---- orders
        weekend = day.weekday() >= 5
        n_orders = int(args.orders_per_day * (1.35 if weekend else 1.0) * rng.uniform(0.85, 1.15))
        candidates = [c for c in customers if c["CreatedAt"].date() <= day]
        for _ in range(n_orders):
            order_id += 1
            cust = rng.choice(new_today) if new_today and rng.random() < 0.05 else rng.choice(candidates)
            region = COUNTRY_REGION[cust["Country"]]
            online = rng.random() < 0.55
            store = None if online else rng.choice(stores_by_region[region])
            ts = dt.datetime.combine(day, dt.time(rng.randint(7, 22), rng.randint(0, 59), rng.randint(0, 59)))
            age = (end - day).days
            status = ("Delivered" if age > 6 else rng.choice(["Placed", "Shipped", "Delivered"]))
            r = rng.random()
            if r < 0.03:
                status = "Cancelled"
            elif r < 0.05 and status == "Delivered":
                status = "Returned"
            shipping = None
            if online:
                shipping = {"carrier": rng.choice(["Omniva", "DPD", "PostNord", "DHL", "InPost"]),
                            "tracking": f"{rng.randint(10**11, 10**12 - 1)}",
                            "address": {"city": cust["City"], "country": cust["Country"]},
                            "express": rng.random() < 0.15}
            orders.append({"OrderID": order_id, "CustomerID": cust["CustomerID"],
                           "StoreID": store[0] if store else None,
                           "Channel": "Online" if online else "Store",
                           "SalesRegion": COUNTRY_REGION[store[4]] if store else region,
                           "OrderDate": ts, "Status": status, "ShippingInfo": shipping,
                           "ModifiedAt": ts + dt.timedelta(hours=rng.randint(0, 72)) if status != "Placed" else ts})
            chosen = rng.choices(active_products, weights=weights, k=rng.choice([1, 1, 1, 2, 2, 3, 4]))
            seen = set()
            ln = 0
            for p in chosen:
                if p["ProductID"] in seen:
                    continue
                seen.add(p["ProductID"])
                ln += 1
                disc = rng.choice([0, 0, 0, 0.1, 0.15]) if cust["LoyaltyTier"] != "Bronze" else rng.choice([0, 0, 0, 0, 0.1])
                qty = 1 if p["CategoryID"] not in (6, 14, 18) else rng.choice([1, 1, 2, 3])
                lines.append({"OrderID": order_id, "LineNumber": ln, "ProductID": p["ProductID"],
                              "Quantity": qty, "UnitPrice": p["ListPrice"], "DiscountPct": disc})
                # review for some delivered lines
                if status == "Delivered" and rng.random() < 0.2:
                    review_id += 1
                    reviews.append(make_review(rng, review_id, p, cust["CustomerID"], day))
            # support ticket for ~5% of orders
            if rng.random() < 0.05:
                ticket_id += 1
                tickets.append(make_ticket(rng, ticket_id, cust, order_id, prod_by_id[next(iter(seen))], ts))

        # ---- clickstream (web events)
        events.extend(make_events(rng, day, customers, active_products))

    return {
        "start": start, "end": end, "products": products, "product_snapshot_day0": product_snapshot_day0,
        "customers": customers, "customer_snapshot_day0": customer_snapshot_day0,
        "customer_changes": customer_changes, "product_changes": product_changes,
        "late_customer_ids": late_customer_ids, "near_dups": near_dups,
        "orders": orders, "lines": lines, "reviews": reviews, "tickets": tickets, "events": events,
    }


def make_review(rng: random.Random, rid: int, p: dict, customer_id: int, day: dt.date) -> dict:
    q = p["Quality"]
    rating = max(1, min(5, round(rng.gauss(1 + q * 4.4, 0.9))))
    pos, neg = T.REVIEW_ASPECTS[p["CategoryID"]]
    if rating >= 4:
        parts = [rng.choice(T.REVIEW_OPENERS_POS)] + [s.capitalize() + "." for s in rng.sample(pos, k=min(2, len(pos)))]
        if rating == 4:
            parts.append("Only complaint: " + rng.choice(neg) + ".")
        parts.append(rng.choice(T.REVIEW_CLOSERS_POS))
    elif rating == 3:
        parts = [rng.choice(T.REVIEW_OPENERS_NEG), rng.choice(pos).capitalize() + ", but " + rng.choice(neg) + "."]
    else:
        parts = [rng.choice(T.REVIEW_OPENERS_NEG)] + [s.capitalize() + "." for s in rng.sample(neg, k=min(2, len(neg)))]
        parts.append(rng.choice(T.REVIEW_CLOSERS_NEG))
    return {"ReviewID": rid, "ProductID": p["ProductID"], "CustomerID": customer_id, "Rating": rating,
            "Title": rng.choice(T.TITLES_BY_RATING[rating]), "ReviewText": " ".join(parts),
            "ReviewDate": day + dt.timedelta(days=rng.randint(3, 14))}


def messy_phone(rng: random.Random, phone: str) -> str:
    digits = "".join(ch for ch in phone if ch.isdigit())
    return rng.choice([phone, f"({digits[:3]}) {digits[3:]}", f"{digits[-8:-6]}-{digits[-6:-3]}-{digits[-3:]}", "+" + digits])


def make_ticket(rng: random.Random, tid: int, cust: dict, order_id: int, p: dict, ts: dt.datetime) -> dict:
    subject, body = rng.choice(T.TICKET_TEMPLATES)
    body = body.format(order=f"TH-{order_id:08d}", product=p["ProductName"], phone=messy_phone(rng, cust["Phone"]),
                       email=cust["Email"], size=rng.choice(["42", "43", "M", "L", "44.5"]))
    return {"TicketID": tid, "CustomerID": cust["CustomerID"], "ProductID": p["ProductID"], "OrderID": order_id,
            "OpenedAt": ts + dt.timedelta(days=rng.randint(1, 10), hours=rng.randint(0, 12)),
            "Channel": rng.choice(["Email", "Chat", "Phone"]), "Subject": subject, "Body": body,
            "Status": rng.choice(["Open", "Pending", "Resolved", "Closed", "Closed"]),
            "Priority": rng.choices(["Low", "Medium", "High", "Urgent"], weights=[0.3, 0.45, 0.2, 0.05])[0]}


def make_events(rng: random.Random, day: dt.date, customers: list[dict], products: list[dict]) -> list[dict]:
    out = []
    n_sessions = rng.randint(120, 180)
    devices = ["mobile", "desktop", "tablet"]
    for s in range(n_sessions):
        cust = rng.choice(customers) if rng.random() < 0.6 else None
        country = cust["Country"] if cust else rng.choice(list(COUNTRY_REGION))
        sid = f"{day:%Y%m%d}-{s:05d}"
        t = dt.datetime.combine(day, dt.time(rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59)))
        device = rng.choice(devices)
        steps = [("page_view", "/", None)]
        if rng.random() < 0.6:
            steps.append(("search", "/search", None))
        viewed = rng.sample(products, k=rng.randint(1, 4))
        steps += [("product_view", f"/p/{p['SKU']}", p) for p in viewed]
        if rng.random() < 0.3:
            steps.append(("add_to_cart", "/cart", viewed[-1]))
            if rng.random() < 0.5:
                steps += [("checkout", "/checkout", None), ("purchase", "/checkout/complete", None)]
        for i, (etype, page, prod) in enumerate(steps):
            t += dt.timedelta(seconds=rng.randint(4, 180))
            out.append({"event_id": f"{sid}-{i:02d}", "event_time": t.isoformat(timespec="seconds") + "Z",
                        "session_id": sid, "customer_id": cust["CustomerID"] if cust else None,
                        "event_type": etype, "page": page, "product_id": prod["ProductID"] if prod else None,
                        "search_term": rng.choice(T.SEARCH_TERMS) if etype == "search" else None,
                        "device": device, "country": country,
                        "duration_ms": rng.randint(200, 9000)})
    return out


# --------------------------------------------------------------------------------------
# Writers
# --------------------------------------------------------------------------------------

def fmt(v):
    if v is None:
        return ""
    if isinstance(v, dt.datetime):
        return v.isoformat(timespec="seconds")
    if isinstance(v, dt.date):
        return v.isoformat()
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return v


def write_csv(path: Path, rows: list[dict], cols: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            w.writerow([fmt(r.get(c)) for c in cols])


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps({k: fmt(v) if isinstance(v, (dt.date, dt.datetime)) else v for k, v in r.items()},
                               ensure_ascii=False) + "\n")


CUSTOMER_COLS = ["CustomerID", "CustomerCode", "FirstName", "LastName", "Email", "Phone", "City", "Country",
                 "LoyaltyTier", "CreatedAt", "ReferredByCustomerID"]
PRODUCT_COLS = ["ProductID", "SKU", "ProductName", "CategoryID", "Brand", "ListPrice", "StandardCost",
                "Attributes", "Description", "IsActive"]
ORDER_COLS = ["OrderID", "CustomerID", "StoreID", "Channel", "SalesRegion", "OrderDate", "Status",
              "ShippingInfo", "ModifiedAt"]
LINE_COLS = ["OrderID", "LineNumber", "ProductID", "Quantity", "UnitPrice", "DiscountPct"]


def write_landing(data: dict, out: Path, rng: random.Random) -> dict:
    """Write the DP-700 landing zone with injected data-quality problems. Returns injected-issue counts."""
    land = out / "landing"
    start = data["start"]
    issues = Counter()

    write_csv(land / "reference" / "categories.csv",
              [{"CategoryID": c[0], "CategoryName": c[1], "Department": c[2]} for c in T.CATEGORIES],
              ["CategoryID", "CategoryName", "Department"])
    write_csv(land / "reference" / "stores.csv",
              [{"StoreID": s[0], "StoreCode": s[1], "StoreName": s[2], "City": s[3], "Country": s[4],
                "Region": COUNTRY_REGION[s[4]], "OpenedOn": s[5]} for s in STORES],
              ["StoreID", "StoreCode", "StoreName", "City", "Country", "Region", "OpenedOn"])

    # Day-0 full extracts (customers with quality issues)
    full = []
    for c in data["customer_snapshot_day0"]:
        c = dict(c)
        r = rng.random()
        if r < 0.02:
            c["Email"] = None; issues["customers_missing_email"] += 1
        elif r < 0.025:
            c["Email"] = c["Email"].replace("@", ".at."); issues["customers_invalid_email"] += 1
        elif r < 0.035:
            c["Country"] = rng.choice([c["Country"].lower(), c["Country"].upper() + " "]); issues["customers_dirty_country"] += 1
        c["Phone"] = messy_phone(rng, c["Phone"])
        full.append(c)
    write_csv(land / "crm" / "customers" / f"load_date={start}" / "customers_full.csv", full, CUSTOMER_COLS)
    write_csv(land / "catalog" / "products" / f"load_date={start}" / "products_full.csv",
              data["product_snapshot_day0"], PRODUCT_COLS)

    for day, rows in sorted(data["customer_changes"].items()):
        write_csv(land / "crm" / "customers" / f"load_date={day + dt.timedelta(days=1)}" / "customers_delta.csv",
                  rows, CUSTOMER_COLS + ["_change"])
    for day, rows in sorted(data["product_changes"].items()):
        write_csv(land / "catalog" / "products" / f"load_date={day + dt.timedelta(days=1)}" / "products_delta.csv",
                  rows, PRODUCT_COLS)

    # Orders + lines. The extract for load_date D holds orders placed on D-1, plus:
    #   * late-arriving orders (placed earlier, delivered to the landing zone 1-4 days late)
    #   * status updates: an order first lands as 'Placed' and its final status arrives in a LATER file
    #     (same OrderID, newer ModifiedAt) -> you must upsert/deduplicate on the latest ModifiedAt
    last_load = data["end"] + dt.timedelta(days=4)
    by_day = defaultdict(list)          # load_date -> list of (order_row, include_lines)
    for o in data["orders"]:
        load = o["OrderDate"].date() + dt.timedelta(days=1)
        if rng.random() < 0.02:                         # late-arriving fact (1-4 days late)
            load += dt.timedelta(days=rng.randint(1, 4)); issues["orders_late_arriving"] += 1
        if o["Status"] != "Placed" and rng.random() < 0.5:
            by_day[load].append((dict(o, Status="Placed", ModifiedAt=o["OrderDate"]), True))
            update_load = min(load + dt.timedelta(days=rng.randint(2, 5)), last_load)
            by_day[update_load].append((dict(o), False))
            issues["orders_status_updates"] += 1
        else:
            by_day[load].append((dict(o), True))
    lines_by_order = defaultdict(list)
    for ln in data["lines"]:
        lines_by_order[ln["OrderID"]].append(ln)

    for load_date in sorted(by_day):
        o_rows, l_rows = [], []
        for row, include_lines in by_day[load_date]:
            o = row
            if rng.random() < 0.005:
                row = dict(row, OrderDate=o["OrderDate"].strftime("%d/%m/%Y %H:%M")); issues["orders_bad_date_format"] += 1
            o_rows.append(row)
            if rng.random() < 0.01:
                o_rows.append(dict(row)); issues["orders_exact_duplicates"] += 1
            if not include_lines:
                continue
            for ln in lines_by_order[o["OrderID"]]:
                lr = dict(ln)
                r = rng.random()
                if r < 0.007:
                    lr["UnitPrice"] = None; issues["lines_missing_unit_price"] += 1
                elif r < 0.010:
                    lr["Quantity"] = -lr["Quantity"]; issues["lines_negative_quantity"] += 1
                elif r < 0.012:
                    lr["ProductID"] = 99999; issues["lines_unknown_product"] += 1
                l_rows.append(lr)
                if rng.random() < 0.005:
                    l_rows.append(dict(lr)); issues["lines_exact_duplicates"] += 1
        write_csv(land / "sales" / "orders" / f"load_date={load_date}" / "orders.csv", o_rows, ORDER_COLS)
        write_csv(land / "sales" / "order_lines" / f"load_date={load_date}" / "order_lines.csv", l_rows, LINE_COLS)

    # Reviews (JSON Lines) and tickets (JSON array) by load date
    rev_by_day = defaultdict(list)
    for r in data["reviews"]:
        rev_by_day[r["ReviewDate"] + dt.timedelta(days=1)].append(r)
    for load_date, rows in sorted(rev_by_day.items()):
        write_jsonl(land / "catalog" / "reviews" / f"load_date={load_date}" / "reviews.jsonl", rows)
    tk_by_day = defaultdict(list)
    for t in data["tickets"]:
        tk_by_day[t["OpenedAt"].date() + dt.timedelta(days=1)].append(t)
    for load_date, rows in sorted(tk_by_day.items()):
        p = land / "support" / "tickets" / f"load_date={load_date}" / "tickets.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps([{k: fmt(v) for k, v in t.items()} for t in rows], ensure_ascii=False, indent=1),
                     encoding="utf-8")

    # Clickstream: ~2% of events arrive a day late, ~1% duplicated
    ev_by_day = defaultdict(list)
    for e in data["events"]:
        d = dt.date.fromisoformat(e["event_time"][:10])
        if rng.random() < 0.02:
            d += dt.timedelta(days=1); issues["events_late"] += 1
        ev_by_day[d].append(e)
        if rng.random() < 0.01:
            ev_by_day[d].append(dict(e)); issues["events_duplicates"] += 1
    for d, rows in sorted(ev_by_day.items()):
        write_jsonl(land / "web" / "clickstream" / f"event_date={d}" / "events.jsonl", rows)
    # A flat copy of the events for the streaming simulator
    write_jsonl(out / "stream" / "clickstream_replay.jsonl", sorted(data["events"], key=lambda e: e["event_time"]))
    return dict(issues)


def write_answer_keys(data: dict, out: Path, issues: dict) -> None:
    keys = out / "answer_keys"
    keys.mkdir(parents=True, exist_ok=True)
    orders, lines = data["orders"], data["lines"]
    valid_orders = [o for o in orders if o["Status"] != "Cancelled"]
    valid_ids = {o["OrderID"] for o in valid_orders}
    kept_ids = {o["OrderID"] for o in orders if o["Status"] not in ("Cancelled", "Returned")}
    net = sum(l["Quantity"] * l["UnitPrice"] * (1 - l["DiscountPct"]) for l in lines if l["OrderID"] in valid_ids)
    by_region = Counter()
    order_region = {o["OrderID"]: o["SalesRegion"] for o in orders}
    for l in lines:
        if l["OrderID"] in valid_ids:
            by_region[order_region[l["OrderID"]]] += l["Quantity"] * l["UnitPrice"] * (1 - l["DiscountPct"])
    expected = {
        "_note": "Ground truth BEFORE injected problems. Your silver/gold layers should reproduce these after cleaning, "
                 "except lines you deliberately quarantine (see injected_issues).",
        "distinct_orders": len(orders),
        "distinct_order_lines": len(lines),
        "orders_excluding_cancelled": len(valid_orders),
        "net_sales_excluding_cancelled": round(net, 2),
        "net_sales_by_region_excluding_cancelled": {k: round(v, 2) for k, v in sorted(by_region.items())},
        "net_sales_excluding_cancelled_and_returned": round(sum(
            l["Quantity"] * l["UnitPrice"] * (1 - l["DiscountPct"]) for l in lines if l["OrderID"] in kept_ids), 2),
        "expected_silver_order_lines": len(lines) - issues.get("lines_negative_quantity", 0)
                                       - issues.get("lines_unknown_product", 0),
        "customers_final": len(data["customers"]),
        "products": len(data["products"]),
        "reviews": len(data["reviews"]),
        "tickets": len(data["tickets"]),
        "web_events_distinct": len(data["events"]),
        "late_arriving_customers": len(data["late_customer_ids"]),
        "injected_issues": issues,
    }
    (keys / "expected_counts.json").write_text(json.dumps(expected, indent=2), encoding="utf-8")
    with (keys / "near_duplicate_customers.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["OriginalCustomerID", "DuplicateCustomerID"])
        w.writerows(data["near_dups"])


# --------------------------------------------------------------------------------------
# T-SQL seed for DP-800
# --------------------------------------------------------------------------------------

def sql_lit(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v) if isinstance(v, int) else f"{v:.2f}"
    if isinstance(v, dt.datetime):
        return f"'{v.isoformat(sep=' ', timespec='seconds')}'"
    if isinstance(v, dt.date):
        return f"'{v.isoformat()}'"
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    return "N'" + str(v).replace("'", "''") + "'"


def insert_block(table: str, cols: list[str], rows: list[dict], batch: int = 500) -> str:
    out = []
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        values = ",\n".join("(" + ", ".join(sql_lit(r[c]) for c in cols) + ")" for r in chunk)
        out.append(f"INSERT INTO {table} ({', '.join(cols)}) VALUES\n{values};\n")
    return "\n".join(out)


def write_sql_seed(data: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    customers = sorted(data["customers"], key=lambda c: c["CustomerID"])
    max_order = max(o["OrderID"] for o in data["orders"])
    parts = [
        "/* ============================================================================",
        "   02_seed_data.sql  -  GENERATED by data-generator/generate_data.py. Do not edit.",
        f"   Seed {len(customers)} customers, {len(data['products'])} products, {len(data['orders'])} orders,",
        f"   {len(data['lines'])} order lines, {len(data['reviews'])} reviews, {len(data['tickets'])} tickets.",
        "   Run after 01_schema.sql. Re-runnable: it deletes existing rows first.",
        "   ============================================================================ */",
        "SET NOCOUNT ON;",
        "SET XACT_ABORT ON;",
        "BEGIN TRANSACTION;",
        "",
        "-- Clear in FK-safe order (system-versioned Customer keeps history - fine for a lab)",
        "IF OBJECT_ID(N'crm.CustomerPII', N'U') IS NOT NULL DELETE FROM crm.CustomerPII;   -- created in lab 5",
        "DELETE FROM support.Ticket; DELETE FROM catalog.ProductReview; DELETE FROM sales.SalesOrderLine;",
        "DELETE FROM sales.SalesOrder;",
        "UPDATE crm.Customer SET ReferredByCustomerID = NULL WHERE ReferredByCustomerID IS NOT NULL;",
        "DELETE FROM crm.Customer; DELETE FROM catalog.Product;",
        "DELETE FROM sales.Store; DELETE FROM catalog.Category;",
        "",
        insert_block("catalog.Category", ["CategoryID", "CategoryName", "Department"],
                     [{"CategoryID": c[0], "CategoryName": c[1], "Department": c[2]} for c in T.CATEGORIES]),
        insert_block("sales.Store", ["StoreID", "StoreCode", "StoreName", "City", "Country", "Region", "OpenedOn"],
                     [{"StoreID": s[0], "StoreCode": s[1], "StoreName": s[2], "City": s[3], "Country": s[4],
                       "Region": COUNTRY_REGION[s[4]], "OpenedOn": dt.date.fromisoformat(s[5])} for s in STORES]),
        insert_block("catalog.Product", ["ProductID", "SKU", "ProductName", "CategoryID", "Brand", "ListPrice",
                                         "StandardCost", "Attributes", "Description", "IsActive"], data["products"]),
        "-- Customers: insert without referrals first, then set ReferredByCustomerID (self-referencing FK)",
        insert_block("crm.Customer", [c for c in CUSTOMER_COLS if c != "ReferredByCustomerID"], customers),
        "UPDATE c SET ReferredByCustomerID = v.ReferredBy FROM crm.Customer AS c JOIN (VALUES\n"
        + ",\n".join(f"({c['CustomerID']}, {c['ReferredByCustomerID']})" for c in customers if c["ReferredByCustomerID"])
        + "\n) AS v(CustomerID, ReferredBy) ON v.CustomerID = c.CustomerID;\n",
        insert_block("sales.SalesOrder", ["OrderID", "CustomerID", "StoreID", "Channel", "SalesRegion", "OrderDate",
                                          "Status", "ShippingInfo", "ModifiedAt"], data["orders"]),
        insert_block("sales.SalesOrderLine", LINE_COLS, data["lines"]),
        insert_block("catalog.ProductReview", ["ReviewID", "ProductID", "CustomerID", "Rating", "Title",
                                               "ReviewText", "ReviewDate"], data["reviews"]),
        insert_block("support.Ticket", ["TicketID", "CustomerID", "ProductID", "OrderID", "OpenedAt", "Channel",
                                        "Subject", "Body", "Status", "Priority"], data["tickets"]),
        "COMMIT;",
        "",
        "-- The sequence must continue after the seeded keys (lab: what happens if you skip this?)",
        f"ALTER SEQUENCE sales.OrderIDSeq RESTART WITH {max_order + 1};",
        "",
        "SELECT 'Category' AS TableName, COUNT(*) AS RowsLoaded FROM catalog.Category UNION ALL",
        "SELECT 'Store', COUNT(*) FROM sales.Store UNION ALL",
        "SELECT 'Product', COUNT(*) FROM catalog.Product UNION ALL",
        "SELECT 'Customer', COUNT(*) FROM crm.Customer UNION ALL",
        "SELECT 'SalesOrder', COUNT(*) FROM sales.SalesOrder UNION ALL",
        "SELECT 'SalesOrderLine', COUNT(*) FROM sales.SalesOrderLine UNION ALL",
        "SELECT 'ProductReview', COUNT(*) FROM catalog.ProductReview UNION ALL",
        "SELECT 'Ticket', COUNT(*) FROM support.Ticket;",
    ]
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    data = simulate(args)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    issues = write_landing(data, out, random.Random(args.seed + 1))
    write_answer_keys(data, out, issues)
    if args.sql_seed:
        write_sql_seed(data, Path(args.sql_seed))
    print(f"Wrote landing zone to {out / 'landing'}")
    print(f"  {len(data['customers'])} customers, {len(data['products'])} products, {len(data['orders'])} orders, "
          f"{len(data['lines'])} lines, {len(data['reviews'])} reviews, {len(data['tickets'])} tickets, "
          f"{len(data['events'])} web events")
    print(f"  injected issues: {issues}")
    print(f"Answer keys in {out / 'answer_keys'}")
    if args.sql_seed:
        print(f"T-SQL seed written to {args.sql_seed}")


if __name__ == "__main__":
    main()
