#!/bin/sh
# Ground truth for realm-lago: every figure this realm reports, re-asked of Lago directly
# through its own API, and required to agree EXACTLY. Exits nonzero on any drift.
#
#   LAGO=http://127.0.0.1:3200 LAGO_API_KEY=... \
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# Four layers, each against the one before: Lago itself; what a narrow question COSTS (it must
# be sent to Lago narrowed, so one customer is a call or two, not the book); a traversal through
# the business vocabulary's labels; the saved views. A figure that reconciles at the view and not
# at the traversal means the view is compensating for something, and that is a finding.
#
# The cost layer reads the appliance's own count of source calls (`apiCalls` on a query,
# `metrics.externalCalls` on a view). Set LAGO_CONTAINER to the Lago API container's name
# (account-health-demo-lago-api-1 for the demo stack) and it also reads Lago's request log — the
# raw HTTP the source received — and requires the pushed filter to be on the request. It runs
# BEFORE anything sweeps the books: a read the cache answers costs 0 calls, which passes the bound
# but proves nothing about the request, and the battery says so when it happens.
#
# L3 needs a CRM realm installed whose accounts key the CustomerAccount spine (realm-odoo):
# it is the join this realm exists for, and an account join that returns zero rows passes
# every other check here. Set SKIP_ACCOUNT_JOIN=1 to run without one.
set -e
# Either AUTH=user:pass or TOKEN=<appliance API key>. Both go to curl through a config file, so
# neither appears on a command line where `ps` would show it.
AUTHCFG=$(mktemp); TRUTHF=$(mktemp); trap 'rm -f "$AUTHCFG" "$TRUTHF"' EXIT
if [ -n "${TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTHCFG"
else printf 'user = "%s"\n' "${AUTH:?set AUTH (user:pass) or TOKEN}" > "$AUTHCFG"; fi
LAGO="${LAGO:-http://127.0.0.1:3200}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${LAGO_API_KEY:?set LAGO_API_KEY}"
fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
# at_most name bound actual — a cost: the source calls a question made, which must not exceed the bound.
at_most() {
  case "$3" in ''|*[!0-9]*) echo "  FAIL $1: no call count ($3)"; fail=1; return ;; esac
  if [ "$3" -le "$2" ]; then
    if [ "$3" -eq 0 ]; then echo "  ok   $1: 0 source calls (answered from cache — rerun after the cache window to see the request)"
    else echo "  ok   $1: $3 source call(s), bound $2"; fi
  else echo "  FAIL $1: $3 source calls, bound $2 — the filter was not sent to Lago"; fail=1; fi
}
kg() { curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys; print(json.dumps({"cypher": sys.argv[1]}))' "$1")"; }
view() { curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/$1/invoke" -H 'Content-Type: application/json' -d "{\"args\":$2}"; }
# A refused query has no rows and an `error`; reading that as 0 once passed an exactness check
# whose query the engine had refused outright. So a refusal prints REFUSED, which no check expects.
n() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("rows") or []; print("REFUSED: " + str(d["error"])[:160] if d.get("error") else (r[0]["n"] if r else 0))'; }
calls() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("apiCalls", ""))'; }
vcalls() { printf '%s' "$1" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("metrics") or {}).get("externalCalls", ""))'; }
# Read from stdin: a whole book of rows passed as an argument is past the system's argument limit.
rows() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["data"]) if isinstance(d.get("data"), list) else "REFUSED: " + str(d.get("error") or d)[:160])'; }
t() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(v)' "$TRUTHF" "$1"; }

echo "== L0: ground truth, from Lago directly =="
LAGO="$LAGO" python3 - "$TRUTHF" <<'PY'
import json, os, sys, urllib.request, collections
base, key = os.environ["LAGO"] + "/api/v1", os.environ["LAGO_API_KEY"]
def every(path, name):
    page = 1
    while page:
        sep = "&" if "?" in path else "?"
        req = urllib.request.Request(f"{base}{path}{sep}per_page=200&page={page}", headers={"Authorization": "Bearer " + key})
        d = json.load(urllib.request.urlopen(req))
        yield from d[name]
        page = d["meta"].get("next_page")
ALL = "status[]=active&status[]=pending&status[]=canceled&status[]=terminated&status[]=incomplete"
customers = list(every("/customers", "customers"))
invoices = list(every("/invoices?status=finalized", "invoices"))
subs = list(every("/subscriptions", "subscriptions"))           # Lago's default: active only
anysubs = list(every("/subscriptions?" + ALL, "subscriptions"))
plans = {p["code"]: p for p in every("/plans", "plans")}
unpaid = [i for i in invoices if i["payment_status"] != "succeeded"]
owed = collections.Counter()
for i in unpaid: owed[i["customer"]["name"]] += i["total_due_amount_cents"]
top = sorted(owed.items(), key=lambda kv: (-kv[1], kv[0]))[0]
by_plan = collections.Counter(plans.get(s["plan_code"], {}).get("name", "?") for s in subs)
top_plan, top_plan_n = by_plan.most_common(1)[0]
# The probe customer: a name no other customer shares (so "exactly this name" has one answer), the
# most invoices among those with something unpaid, ties to the smallest external id.
names = collections.Counter(c["name"] for c in customers)
mine = collections.defaultdict(list)
for i in invoices: mine[i["customer"]["external_id"]].append(i)
probe = sorted((c for c in customers if names[c["name"]] == 1
                and any(i["payment_status"] != "succeeded" for i in mine[c["external_id"]])),
               key=lambda c: (-len(mine[c["external_id"]]), c["external_id"]))[0]
probe_invoices = mine[probe["external_id"]]
probe_owed = collections.Counter()
for i in probe_invoices:
    if i["payment_status"] != "succeeded": probe_owed[i["currency"]] += i["total_due_amount_cents"]
# The window: the earliest issue day holding between 1 and 200 invoices, so it fits one page.
per_day = collections.Counter(i["issuing_date"] for i in invoices)
day = sorted(d for d, k in per_day.items() if 1 <= k <= 200)[0]
plan_code, plan_n = collections.Counter(s["plan_code"] for s in subs).most_common(1)[0]
periods = {"weekly": 52, "monthly": 12, "quarterly": 4, "semiannual": 2, "yearly": 1}
annual = collections.Counter()
for s in subs:
    annual[s["plan_amount_currency"]] += s["plan_amount_cents"] * periods[plans[s["plan_code"]]["interval"]]
json.dump({
    "customers": len(customers), "invoices": len(invoices), "subs": len(subs), "anysubs": len(anysubs),
    "ended": sum(s["status"] in ("terminated", "canceled") for s in anysubs),
    "unpaid": len(unpaid), "failed": sum(i["payment_status"] == "failed" for i in invoices),
    "dueCents": sum(i["total_due_amount_cents"] for i in unpaid),
    "unpaidGBP": sum(i["currency"] == "GBP" for i in unpaid),
    "top": top[0], "topCents": top[1], "plans": len(plans), "topPlan": f"{top_plan}:{top_plan_n}",
    "probeId": probe["external_id"], "probeName": probe["name"], "probeInvoices": len(probe_invoices),
    "probeOwed": ",".join(f"{c}:{v}" for c, v in sorted(probe_owed.items())),
    "day": day, "dayInvoices": per_day[day], "planCode": plan_code, "planSubs": plan_n,
    "annual": ",".join(f"{c}:{v}" for c, v in sorted(annual.items())),
}, open(sys.argv[1], "w"))
PY
CUSTOMERS=$(t customers) INVOICES=$(t invoices) SUBS=$(t subs) ANYSUBS=$(t anysubs) UNPAID=$(t unpaid)
FAILED=$(t failed) DUE_CENTS=$(t dueCents) TOP=$(t top) TOP_CENTS=$(t topCents)
PROBE_ID=$(t probeId) PROBE_NAME=$(t probeName) PROBE_INVOICES=$(t probeInvoices) PROBE_OWED=$(t probeOwed)
DAY=$(t day) DAY_INVOICES=$(t dayInvoices) PLAN_CODE=$(t planCode) PLAN_SUBS=$(t planSubs)
echo "  customers=$CUSTOMERS invoices=$INVOICES subscriptions=$SUBS (every status $ANYSUBS) unpaid=$UNPAID failed=$FAILED dueCents=$DUE_CENTS owesMost=$TOP:$TOP_CENTS"
echo "  probe customer $PROBE_ID ($PROBE_NAME): $PROBE_INVOICES invoices, owes $PROBE_OWED; day $DAY: $DAY_INVOICES invoices; plan $PLAN_CODE: $PLAN_SUBS active"

echo "== Lc: a narrow question is sent to Lago narrowed (run before anything sweeps the books) =="
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
R=$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer) WHERE c.externalId = '$PROBE_ID' RETURN c.name AS n")
check "one customer by external id" "$PROBE_NAME" "$(echo "$R" | n)"
at_most "one customer by external id" 1 "$(calls "$R")"
R=$(kg "MATCH (b:LagoBooks)-[:HAS_INVOICE]->(i:BillingInvoice) WHERE i.customerExternalId = '$PROBE_ID' RETURN count(i) AS n")
check "one customer's invoices, by external id" "$PROBE_INVOICES" "$(echo "$R" | n)"
at_most "one customer's invoices, by external id" 1 "$(calls "$R")"
V=$(view LagoCustomerInvoices "$(python3 -c 'import json,sys; print(json.dumps({"customer": sys.argv[1]}))' "$PROBE_NAME")")
check "view: one customer's invoices, by exact name" "$PROBE_INVOICES" "$(rows "$V")"
at_most "view: one customer's invoices, by exact name (search + invoices)" 2 "$(vcalls "$V")"
V=$(view LagoCustomerInvoices "$(python3 -c 'import json,sys; print(json.dumps({"customer": sys.argv[1], "paymentStatus": "unpaid"}))' "$PROBE_NAME")")
check "view: what that customer owes, per currency (cents)" "$PROBE_OWED" "$(echo "$V" | python3 -c '
import json,sys,collections; c=collections.Counter()
for r in json.load(sys.stdin)["data"]: c[r["currency"]] += round(r["amountDue"] * 100)
print(",".join(f"{k}:{v}" for k, v in sorted(c.items())))')"
R=$(kg "MATCH (b:LagoBooks)-[:HAS_INVOICE]->(i:BillingInvoice) WHERE i.issuedOn = '$DAY' RETURN count(i) AS n")
check "invoices Lago issued on $DAY" "$DAY_INVOICES" "$(echo "$R" | n)"
at_most "invoices Lago issued on one day" 1 "$(calls "$R")"
V=$(view LagoInvoicesIssued "{\"issuedFrom\":\"$DAY\",\"issuedTo\":\"$DAY\",\"limit\":100000}")
check "view: invoices issued in a one-day window" "$DAY_INVOICES" "$(rows "$V")"
at_most "view: invoices issued in a one-day window" 1 "$(vcalls "$V")"
R=$(kg "MATCH (b:LagoBooks)-[:HAS_SUBSCRIPTION]->(s:BillingSubscription) WHERE s.planCode = '$PLAN_CODE' RETURN count(s) AS n")
check "active subscriptions on plan $PLAN_CODE" "$PLAN_SUBS" "$(echo "$R" | n)"
at_most "a count on one plan is Lago's own total" 1 "$(calls "$R")"
R=$(kg "MATCH (b:LagoBooks)-[:HAS_ANY_SUBSCRIPTION]->(s:BillingSubscription) WHERE s.status IN ['terminated', 'canceled'] RETURN count(s) AS n")
check "subscriptions that ended or never started" "$(t ended)" "$(echo "$R" | n)"
at_most "a count over two statuses is Lago's own total" 1 "$(calls "$R")"
R=$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer) RETURN count(c) AS n")
check "customers, counted" "$CUSTOMERS" "$(echo "$R" | n)"
at_most "a count of customers is Lago's own total" 1 "$(calls "$R")"
if [ -n "${LAGO_CONTAINER:-}" ] && docker logs --since "$T0" "$LAGO_CONTAINER" >/dev/null 2>&1; then
  # Lago logs one JSON line per request (lograge), with its params. Other clients share the Lago, so
  # the check is that the narrow requests carry their filter — never a count of everything it served.
  docker logs --since "$T0" "$LAGO_CONTAINER" 2>/dev/null | python3 -c '
import json, sys
probe_id, probe_name, day, plan = sys.argv[1:5]
seen = []
for line in sys.stdin:
    try: r = json.loads(line)
    except ValueError: continue
    if r.get("method") == "GET" and str(r.get("path", "")).startswith("/api/v1/"): seen.append((r["path"], r.get("params") or {}))
want = {
  "customer by external id": lambda p, q: p == "/api/v1/customers" and q.get("external_id") == probe_id,
  "invoices by customer":    lambda p, q: p == "/api/v1/invoices" and q.get("external_customer_id") == probe_id,
  "customer search by name": lambda p, q: p == "/api/v1/customers" and q.get("search_term") == probe_name,
  "invoices on one day":     lambda p, q: p == "/api/v1/invoices" and q.get("issuing_date_from") == day and q.get("issuing_date_to") == day,
  "subscriptions on a plan": lambda p, q: p == "/api/v1/subscriptions" and q.get("plan_code") == plan,
}
for name, match in want.items():
    hits = [q for p, q in seen if match(p, q)]
    print(("  ok   " if hits else "  note ") + "Lago received " + name + ": " + (json.dumps(hits[0]) if hits else "no such request (the appliance answered from cache)"))
' "$PROBE_ID" "$PROBE_NAME" "$DAY" "$PLAN_CODE"
else
  echo "  SKIP Lago's request log: set LAGO_CONTAINER to the Lago API container to read the raw requests"
fi

echo "== L1: the traversal, by the VOCABULARY's labels, reconciles =="
check "customers, asked for as BillingCustomer" "$CUSTOMERS" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer) RETURN count(c) AS n" | n)"
check "the same customers, asked for as LagoCustomer" "$CUSTOMERS" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:LagoCustomer) RETURN count(c) AS n" | n)"
check "invoices, asked for as BillingInvoice" "$INVOICES" "$(kg "MATCH (b:LagoBooks)-[:HAS_INVOICE]->(i:BillingInvoice) RETURN count(i) AS n" | n)"
check "active subscriptions" "$SUBS" "$(kg "MATCH (b:LagoBooks)-[:HAS_SUBSCRIPTION]->(s:BillingSubscription) RETURN count(s) AS n" | n)"
# Two doors lead to subscriptions; a bare label takes the one declared implicitDoor, the active one.
check "a bare BillingSubscription means the active ones" "$SUBS" "$(kg "MATCH (s:BillingSubscription) RETURN count(s) AS n" | n)"
check "subscriptions in every status" "$ANYSUBS" "$(kg "MATCH (b:LagoBooks)-[:HAS_ANY_SUBSCRIPTION]->(s:BillingSubscription) RETURN count(s) AS n" | n)"
check "subscriptions reached THROUGH their customers" "$SUBS" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer)-[:HAS_SUBSCRIPTION]->(s:BillingSubscription) RETURN count(s) AS n" | n)"
check "invoices reached THROUGH their customers" "$INVOICES" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer)-[:HAS_INVOICE]->(i:BillingInvoice) RETURN count(i) AS n" | n)"
check "cents still owed" "$DUE_CENTS" "$(kg "MATCH (b:LagoBooks)-[:HAS_INVOICE]->(i:BillingInvoice) WHERE i.paymentStatus <> 'succeeded' RETURN sum(i.amountDueCents) AS n" | n)"

echo "== L1b: plans, and every subscription reaches its plan =="
check "plans, asked for as BillingPlan" "$(t plans)" "$(kg "MATCH (b:LagoBooks)-[:HAS_PLAN]->(p:BillingPlan) RETURN count(p) AS n" | n)"
check "subscriptions that reach their plan by ON_PLAN" "$SUBS" "$(kg "MATCH (b:LagoBooks)-[:HAS_SUBSCRIPTION]->(s:BillingSubscription)-[:ON_PLAN]->(p:BillingPlan) RETURN count(s) AS n" | n)"
V=$(view LagoPlanMix '{}')
check "view: the plan most subscriptions are on, by name" "$(t topPlan)" "$(echo "$V" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"][0]; print("%s:%d" % (r["plan"], r["activeSubscriptions"]))')"
check "view: plan mix covers every active subscription" "$SUBS" "$(echo "$V" | python3 -c 'import json,sys; print(sum(r["activeSubscriptions"] for r in json.load(sys.stdin)["data"]))')"

echo "== L2: the views reconcile =="
V=$(view LagoPaymentStatusCounts '{}')
check "view: failed invoices" "$FAILED" "$(echo "$V" | python3 -c 'import json,sys; print(sum(r["invoices"] for r in json.load(sys.stdin)["data"] if r["paymentStatus"] == "failed"))')"
V=$(view LagoUnpaidInvoices '{"limit":100000}')
check "view: unpaid invoices (empty filters must not filter)" "$UNPAID" "$(rows "$V")"
V=$(view LagoUnpaidInvoices '{"paymentStatus":"failed","limit":100000}')
check "view: unpaid, failed only" "$FAILED" "$(rows "$V")"
V=$(view LagoUnpaidInvoices '{"currency":"GBP","limit":100000}')
check "view: unpaid, in GBP" "$(t unpaidGBP)" "$(rows "$V")"
V=$(view LagoReceivablesByCustomer '{}')
check "view: who owes most, and how much" "$TOP:$TOP_CENTS" "$(echo "$V" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"][0]; print("%s:%d" % (r["customer"], round(r["amountDue"] * 100)))')"
V=$(view LagoRecurringRevenue '{"limit":100000}')
check "view: active subscriptions" "$SUBS" "$(echo "$V" | python3 -c 'import json,sys; print(sum(r["activeSubscriptions"] for r in json.load(sys.stdin)["data"]))')"
check "view: annual recurring revenue per currency (cents), through each plan's interval" "$(t annual)" "$(echo "$V" | python3 -c '
import json,sys,collections; c=collections.Counter()
for r in json.load(sys.stdin)["data"]: c[r["currency"]] += round(r["annualRecurring"] * 100)
print(",".join(f"{k}:{v}" for k, v in sorted(c.items())))')"
check "view: every customer row carries a name" "0" "$(echo "$V" | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin)["data"] if not r["customer"]))')"
V=$(view LagoSubscriptionsByStatus '{"status":"active","limit":100000}')
check "view: subscriptions by status, active" "$SUBS" "$(rows "$V")"

if [ -z "$SKIP_ACCOUNT_JOIN" ]; then
  echo "== L3: an account the CRM knows reaches what billing knows =="
  # Accounts exist once a CRM realm's customers have been read; read them.
  kg "MATCH (b:OdooBook)-[:HAS_CUSTOMER]->(c:OdooCustomer) RETURN count(c) AS n" >/dev/null
  # The books' customers are swept first, so BILLED_AS rides them (ridesHub) at any book size.
  BILLED=$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer) MATCH (a:CustomerAccount)-[:BILLED_AS]->(c) RETURN count(DISTINCT a) AS n" | n)
  if [ "$BILLED" -gt 0 ]; then echo "  ok   accounts joined to a billing customer = $BILLED (non-zero)"
  else echo "  FAIL accounts joined to a billing customer: 0 — the cross-realm join is not there"; fail=1; fi
  # Exactness: every link is the SAME company. Lago's search is a substring match.
  WRONG=$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer) MATCH (a:CustomerAccount)-[:BILLED_AS]->(c) WHERE NOT toLower(c.url) CONTAINS a.accountKey RETURN count(c) AS n" | n)
  check "billing customers linked to an account that is not theirs" "0" "$WRONG"
fi

echo "== the write verbs, against a disposable Lago =="
# Opt-in: it starts and removes a second Lago in Docker, which takes a minute and some memory.
if [ "$VERIFY_WRITES" = 1 ]; then
  sh "$(dirname "$0")/verify-writes.sh" || fail=1
else
  echo "  SKIP: set VERIFY_WRITES=1 to exercise the write verbs"
fi

[ $fail -eq 0 ] && echo "ALL CHECKS PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
