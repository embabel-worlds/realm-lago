#!/usr/bin/env python3
"""Load the billing part of a neutral book into Lago, through Lago's own REST API.

A BOOK is a directory of product-neutral CSVs (crm/, support/, billing/) joined by
`account_key`, the customer's domain. This loader reads only billing/ and knows only Lago.

    LAGO_API_KEY=... ./load_book.py --book ~/dev/sample-business-data/book --yes
    LAGO_API_KEY=... ./load_book.py --book ... --remove --yes

It follows the realm spec's rules for seeds: it refuses to run without --yes, a second run
changes nothing, and what it creates is recognizable (every invoice carries the book's own
id in its metadata, every customer and subscription uses the book's id as its external id).

WHAT OPEN-SOURCE LAGO WILL AND WILL NOT HOLD. This matters more than anything else here,
because a loader that quietly drops what does not fit produces a demo that lies.

  First-class, and loaded as such: customers, plans, subscriptions with their real start
  dates, invoices with exact amounts and currencies, each invoice's payment status, and a
  lost dispute.

  Not available without a Lago licence (the API answers `feature_unavailable`): recording a
  payment, and issuing a credit note. So individual payment attempts and refunds cannot
  exist as records. They are carried in the invoice's metadata instead — honest, readable
  in Lago's UI, and visibly second-class.

  Not possible at all: back-dating an invoice. Lago stamps today. The book's own issue, due
  and paid dates are carried in metadata, and that is the date a reader should trust.

  Deliberately not loaded: cancelled subscriptions. Lago has no way to record one that has
  already ended; terminating a live one bills the customer a prorated invoice that the book
  never contained.
"""

import argparse
import csv
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Lago's own limits, found by asking it: a metadata value over ~100 characters, a key over
# 20, or a sixth pair on one invoice is refused.
VALUE_MAX = 100


class Lago:
    def __init__(self, url, key):
        self.url, self.key = url.rstrip("/") + "/api/v1", key

    def call(self, method, path, body=None, ok=()):
        req = urllib.request.Request(self.url + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in ok:
                return None
            raise SystemExit(f"Lago refused {method} {path}: {e.code} {e.read().decode(errors='replace')[:400]}")

    def every(self, path, key):
        page, out = 1, []
        while page:
            sep = "&" if "?" in path else "?"
            d = self.call("GET", f"{path}{sep}per_page=100&page={page}")
            out += d[key]
            page = d["meta"].get("next_page")
        return out


def rows(book, name):
    with open(book / name, newline="") as f:
        return list(csv.DictReader(f))


def cents(amount):
    return round(float(amount) * 100)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


# A book records a country the way a person writes it; Lago wants ISO 3166-1 alpha-2 and
# rejects the whole customer otherwise — `422 not_a_valid_country_code`, which failed the
# entire billing load of a 2,000-account book on the first row. The book is the neutral
# format and should not learn Lago's spelling, so the translation lives here.
COUNTRIES = {
    "united states": "US", "usa": "US", "united states of america": "US",
    "united kingdom": "GB", "uk": "GB", "great britain": "GB",
    "germany": "DE", "australia": "AU", "canada": "CA", "france": "FR",
    "ireland": "IE", "netherlands": "NL", "spain": "ES", "italy": "IT",
    "new zealand": "NZ", "japan": "JP", "singapore": "SG", "india": "IN",
    # The Nordics and the rest of western Europe. Added after a 2,000-account book put 124
    # customers in Stockholm and every one of them reached Lago with no country at all —
    # silently, because an unknown country degrades to "send without one" rather than
    # failing. A gap in this table is invisible in the load and shows up later as a
    # customer whose country is null for no reason anyone can see.
    "sweden": "SE", "norway": "NO", "denmark": "DK", "finland": "FI", "iceland": "IS",
    "belgium": "BE", "austria": "AT", "switzerland": "CH", "portugal": "PT",
    "poland": "PL", "czechia": "CZ", "czech republic": "CZ", "luxembourg": "LU",
    "brazil": "BR", "mexico": "MX", "south africa": "ZA",
}


def country_of(value):
    """Lago's `country` field, or NOTHING when the book's spelling is not recognised.

    Omitted rather than guessed: a wrong country is a quiet data error that survives into
    every invoice, while an absent one is visibly absent. Already-valid codes pass through,
    so a book that speaks ISO needs no table entry.
    """
    raw = (value or "").strip()
    if not raw:
        return {}
    if len(raw) == 2 and raw.isalpha():
        return {"country": raw.upper()}
    code = COUNTRIES.get(raw.lower())
    if code:
        return {"country": code}
    print(f"lago: country '{raw}' is not an ISO 3166-1 alpha-2 code and is not in the table — "
          f"sending the customer without one", file=sys.stderr)
    return {}


def field(row, *names):
    """The first of [names] this row actually carries, or "".

    A book is a NEUTRAL format, and neutral formats vary: this loader was written against
    one that recorded a payment's `attempted_on` and `failure_code`, and the generator
    writes `paid_on` and no failure column at all. A bare `row["attempted_on"]` turned that
    difference into `KeyError` partway through a 2,000-account load — after every customer
    and subscription was already in Lago. Reading what is there, and nothing for what is
    not, keeps a thinner book loadable without pretending it said more than it did.
    """
    for name in names:
        if row.get(name):
            return row[name]
    return ""


def links_to(row, payment_ids, invoice_id):
    """Whether a refund or dispute belongs to this invoice, by whichever id its book uses.

    Some books hang a refund off the PAYMENT it reverses, others off the INVOICE. Both are
    reasonable; matching on only one silently attached nothing, which reads exactly like an
    estate with no disputes in it.
    """
    return field(row, "payment_id") in payment_ids and field(row, "payment_id") != "" \
        or field(row, "invoice_id") == invoice_id


# Lago's own words for a billing period. A book may say either the period ("month") or the
# cadence ("monthly") — both are ordinary ways to write it, and a bare dict lookup turned the
# second into `KeyError: 'monthly'` partway through a 2,000-account load, after the customers
# were already in. Accept both, and refuse anything else by NAME rather than by traceback.
INTERVALS = {
    "month": "monthly", "monthly": "monthly",
    "year": "yearly", "yearly": "yearly", "annual": "yearly", "annually": "yearly",
    "week": "weekly", "weekly": "weekly",
    "quarter": "quarterly", "quarterly": "quarterly",
}


def lago_interval(value, source_id):
    code = INTERVALS.get((value or "").strip().lower())
    if not code:
        raise SystemExit(
            f"subscription {source_id} has interval '{value}', which is not one Lago bills on "
            f"({', '.join(sorted(set(INTERVALS.values())))}). Fix the book or add the spelling."
        )
    return code


def days_between(a, b):
    from datetime import date
    return (date.fromisoformat(b) - date.fromisoformat(a)).days


def meta(pairs):
    return [{"key": k, "value": v[:VALUE_MAX]} for k, v in pairs if v]


def load(lago, book):
    made = {"customers": 0, "plans": 0, "subscriptions": 0, "invoices": 0}
    skipped = []
    customers, subs = rows(book, "billing/customers.csv"), rows(book, "billing/subscriptions.csv")
    invoices, payments = rows(book, "billing/invoices.csv"), rows(book, "billing/payments.csv")
    refunds, disputes = rows(book, "billing/refunds.csv"), rows(book, "billing/disputes.csv")

    existing = {c["external_id"] for c in lago.every("/customers", "customers")}
    for c in customers:
        if c["source_id"] in existing:
            continue
        mine = [v for v in invoices if v["customer_id"] == c["source_id"]]
        # Payment terms are not in the book as a column; they are in every invoice as the
        # gap between issue and due date, so that is where they are read from.
        terms = days_between(mine[0]["issued_on"], mine[0]["due_on"]) if mine else 30
        lago.call("POST", "/customers", {"customer": {
            "external_id": c["source_id"], "name": c["name"], "email": c["email"], "phone": c["phone"],
            "currency": c["currency"], **country_of(c["country"]), "url": "https://" + c["account_key"],
            "net_payment_term": terms,
            "metadata": [dict(m, display_in_invoice=False) for m in meta([
                ("account_key", c["account_key"]), ("known_to_crm", c["known_to_crm"]),
                ("payment_method", c["payment_method"]), ("customer_since", c["created_on"]),
                ("note", c["note"])])]}})
        made["customers"] += 1

    plans = {p["code"] for p in lago.every("/plans", "plans")}
    live = {s["external_id"] for s in lago.every("/subscriptions?status[]=active&status[]=pending", "subscriptions")}
    for s in subs:
        if s["status"] == "canceled":
            skipped.append(f"subscription {s['source_id']} ({s['status']} {s['canceled_on']})")
            continue
        if s["plan_code"] not in plans:
            # In arrears, so creating the subscription bills nothing today. The book's
            # invoices are loaded as themselves, below; Lago must not invent a first one.
            lago.call("POST", "/plans", {"plan": {
                "name": s["product"], "code": s["plan_code"], "amount_cents": cents(s["amount"]),
                "amount_currency": s["currency"], "pay_in_advance": False,
                "interval": lago_interval(s["interval"], s["source_id"])}})
            plans.add(s["plan_code"])
            made["plans"] += 1
        if s["source_id"] not in live:
            lago.call("POST", "/subscriptions", {"subscription": {
                "external_customer_id": s["customer_id"], "plan_code": s["plan_code"],
                "external_id": s["source_id"], "name": f"{s['product']} · {s['seats']} seats",
                "billing_time": "anniversary", "subscription_at": s["started_on"] + "T00:00:00Z"}})
            made["subscriptions"] += 1

    product_of = {s["source_id"]: s["product"] for s in subs}
    addons = {a["code"] for a in lago.every("/add_ons", "add_ons")}
    loaded = {}
    for inv in lago.every("/invoices", "invoices"):
        for m in inv.get("metadata") or []:
            if m["key"] == "source":
                loaded[m["value"].split("|")[0]] = inv["lago_id"]

    # Oldest first, so Lago's own sequential numbering runs the same way the book's does.
    for v in sorted(invoices, key=lambda r: r["issued_on"]):
        if v["source_id"] in loaded:
            continue
        product = product_of.get(v["subscription_id"], "One-time services")
        code = f"{slug(product)}_{v['currency'].lower()}"
        if code not in addons:
            lago.call("POST", "/add_ons", {"add_on": {"name": product, "code": code, "amount_cents": 100,
                                                      "amount_currency": v["currency"]}})
            addons.add(code)
        created = lago.call("POST", "/invoices", {"invoice": {
            "external_customer_id": v["customer_id"], "currency": v["currency"],
            "fees": [{"add_on_code": code, "units": 1, "unit_amount_cents": cents(v["amount_due"]),
                      "description": v["description"]}]}})["invoice"]

        attempts = sorted((p for p in payments if p["invoice_id"] == v["source_id"]),
                          key=lambda p: field(p, "attempted_on", "paid_on"))
        pairs = [("source", f"{v['source_id']}|{v['number']}|{v['status']}"),
                 ("dates", f"issued={v['issued_on']};due={v['due_on']};paid={v['paid_on']}")]
        for n, p in enumerate(attempts, 1):
            pairs.append((f"attempt_{n}", ";".join(x for x in (
                p["source_id"], field(p, "attempted_on", "paid_on"), p["status"],
                field(p, "method"), field(p, "failure_code")) if x)))
        ids = {p["source_id"] for p in attempts}
        for r in refunds:
            if links_to(r, ids, v["source_id"]):
                pairs.append(("refund", f"{r['source_id']};{r['refunded_on']};{r['amount']} {r['currency']};{r['reason']}"))
        mine = [d for d in disputes if links_to(d, ids, v["source_id"])]
        for d in mine:
            pairs.append(("dispute", f"{d['source_id']};{d['opened_on']};{d['status']};{d['reason']}"))

        # paid -> succeeded. Open with nothing but failed attempts -> failed. Anything else
        # (open and simply unpaid, or written off as uncollectible) stays pending, because
        # Lago has no word for "we gave up", and the book's own word is in `source`.
        status = ("succeeded" if v["status"] == "paid" else
                  "failed" if attempts and all(p["status"] == "failed" for p in attempts) else "pending")
        lago.call("PUT", f"/invoices/{created['lago_id']}", {"invoice": {"payment_status": status, "metadata": meta(pairs)}})
        if any(d["status"] == "lost" for d in mine):
            lago.call("POST", f"/invoices/{created['lago_id']}/lose_dispute")
        made["invoices"] += 1

    # Count what actually travelled, not what the book holds: a refund or a dispute rides
    # on its payment's invoice, so one whose payment has no invoice did not make the trip.
    invoiced = {p["source_id"] for p in payments if p["invoice_id"]}
    carried = (len(invoiced), sum(r["payment_id"] in invoiced for r in refunds),
               sum(d["payment_id"] in invoiced for d in disputes))
    orphans = [p for p in payments if not p["invoice_id"]]
    for p in orphans:
        skipped.append(f"payment {p['source_id']} ({p['amount']} {p['currency']}) has no invoice, and in Lago a payment "
                       f"cannot exist without one; its refund and dispute go with it")
    return (made, skipped) + carried


def remove(lago, book):
    ours = {c["source_id"] for c in rows(book, "billing/customers.csv")}
    gone = 0
    for c in lago.every("/customers", "customers"):
        if c["external_id"] in ours:
            lago.call("DELETE", f"/customers/{urllib.parse.quote(c['external_id'])}")
            gone += 1
    print(f"lago: removed {gone} customers, and with them their subscriptions and invoices. "
          f"Plans and add-ons are left: they are the price list, and anything may use them.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--book", required=True, type=Path)
    ap.add_argument("--url", default=os.environ.get("LAGO_URL", "http://127.0.0.1:3200"))
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--yes", action="store_true", help="confirm that the target is disposable")
    args = ap.parse_args()
    key = os.environ.get("LAGO_API_KEY") or sys.exit("LAGO_API_KEY is not set")
    if not args.yes:
        sys.exit(f"This would write into {args.url} — a system you must consider disposable.\nRe-run with --yes to proceed.")
    lago = Lago(args.url, key)
    if args.remove:
        return remove(lago, args.book)
    made, skipped, attempts, refunds, disputes = load(lago, args.book)
    print("lago: created " + ", ".join(f"{n} {what}" for what, n in made.items()) if any(made.values())
          else "lago: everything in the book was already there; nothing changed")
    print(f"lago: carried as invoice metadata, not as records (needs a Lago licence) — {attempts} payment attempts, "
          f"{refunds} refunds, {disputes} disputes (a lost dispute IS marked on its invoice).")
    print("lago: invoice dates are today's; the book's issue, due and paid dates are in each invoice's metadata.")
    for s in skipped:
        print("lago: not loaded —", s)


if __name__ == "__main__":
    main()
