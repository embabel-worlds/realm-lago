#!/bin/sh
# Ground truth for realm-lago: every figure this realm reports, re-asked of Lago directly
# through its own API, and required to agree EXACTLY. Exits nonzero on any drift.
#
#   LAGO=http://127.0.0.1:3200 LAGO_API_KEY=... \
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# Three layers, each against the one before: Lago itself, then a traversal through the
# business vocabulary's labels, then the saved views. A figure that reconciles at the view and
# not at the traversal means the view is compensating for something, and that is a finding.
#
# L3 needs a CRM realm installed whose accounts key the CustomerAccount spine (realm-odoo):
# it is the join this realm exists for, and an account join that returns zero rows passes
# every other check here. Set SKIP_ACCOUNT_JOIN=1 to run without one.
set -e
LAGO="${LAGO:-http://127.0.0.1:3200}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${LAGO_API_KEY:?set LAGO_API_KEY}"; : "${AUTH:?set AUTH (user:pass)}"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
kg() { curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys; print(json.dumps({"cypher": sys.argv[1]}))' "$1")"; }
view() { curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/views/$1/invoke" -H 'Content-Type: application/json' -d "{\"args\":$2}"; }
n() { python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"]; print(r[0]["n"] if r else 0)'; }

echo "== L0: ground truth, from Lago directly =="
TRUTH=$(LAGO="$LAGO" python3 - <<'PY'
import json, os, urllib.request, collections
base, key = os.environ["LAGO"] + "/api/v1", os.environ["LAGO_API_KEY"]
def every(path, name):
    page = 1
    while page:
        sep = "&" if "?" in path else "?"
        req = urllib.request.Request(f"{base}{path}{sep}per_page=100&page={page}", headers={"Authorization": "Bearer " + key})
        d = json.load(urllib.request.urlopen(req))
        yield from d[name]
        page = d["meta"].get("next_page")
customers = list(every("/customers", "customers"))
invoices = list(every("/invoices?status=finalized", "invoices"))
subs = list(every("/subscriptions", "subscriptions"))  # active only: all this realm can ask for
unpaid = [i for i in invoices if i["payment_status"] != "succeeded"]
owed = collections.Counter()
for i in unpaid: owed[i["customer"]["name"]] += i["total_due_amount_cents"]
top = sorted(owed.items(), key=lambda kv: (-kv[1], kv[0]))[0]
print(len(customers), len(invoices), len(subs), len(unpaid),
      sum(i["payment_status"] == "failed" for i in invoices),
      sum(i["total_due_amount_cents"] for i in unpaid),
      sum(s["status"] == "active" for s in subs), top[0].replace(" ", "_"), top[1])
PY
)
set -- $TRUTH
CUSTOMERS=$1 INVOICES=$2 SUBS=$3 UNPAID=$4 FAILED=$5 DUE_CENTS=$6 ACTIVE=$7 TOP=$8 TOP_CENTS=$9
echo "  customers=$CUSTOMERS invoices=$INVOICES subscriptions=$SUBS(active $ACTIVE) unpaid=$UNPAID failed=$FAILED dueCents=$DUE_CENTS owesMost=$TOP:$TOP_CENTS"

echo "== L1: the traversal, by the VOCABULARY's labels, reconciles =="
check "customers, asked for as BillingCustomer" "$CUSTOMERS" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer) RETURN count(c) AS n" | n)"
check "the same customers, asked for as LagoCustomer" "$CUSTOMERS" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:LagoCustomer) RETURN count(c) AS n" | n)"
check "invoices, asked for as BillingInvoice" "$INVOICES" "$(kg "MATCH (b:LagoBooks)-[:HAS_INVOICE]->(i:BillingInvoice) RETURN count(i) AS n" | n)"
check "active subscriptions" "$SUBS" "$(kg "MATCH (b:LagoBooks)-[:HAS_SUBSCRIPTION]->(s:BillingSubscription) RETURN count(s) AS n" | n)"
check "subscriptions reached THROUGH their customers" "$SUBS" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer)-[:HAS_SUBSCRIPTION]->(s:BillingSubscription) RETURN count(s) AS n" | n)"
check "invoices reached THROUGH their customers" "$INVOICES" "$(kg "MATCH (b:LagoBooks)-[:HAS_CUSTOMER]->(c:BillingCustomer)-[:HAS_INVOICE]->(i:BillingInvoice) RETURN count(i) AS n" | n)"
check "cents still owed" "$DUE_CENTS" "$(kg "MATCH (b:LagoBooks)-[:HAS_INVOICE]->(i:BillingInvoice) WHERE i.paymentStatus <> 'succeeded' RETURN sum(i.amountDueCents) AS n" | n)"

echo "== L2: the views reconcile =="
V=$(view LagoPaymentStatusCounts '{}')
check "view: failed invoices" "$FAILED" "$(echo "$V" | python3 -c 'import json,sys; print({r["paymentStatus"]: r["invoices"] for r in json.load(sys.stdin)["data"]}.get("failed", 0))')"
V=$(view LagoUnpaidInvoices '{}')
check "view: unpaid invoices (empty filters must not filter)" "$UNPAID" "$(echo "$V" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
V=$(view LagoUnpaidInvoices '{"paymentStatus":"failed"}')
check "view: unpaid, failed only" "$FAILED" "$(echo "$V" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
V=$(view LagoReceivablesByCustomer '{}')
check "view: who owes most, and how much" "$TOP:$TOP_CENTS" "$(echo "$V" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"][0]; print("%s:%d" % (r["customer"].replace(" ", "_"), round(r["amountDue"] * 100)))')"
V=$(view LagoRecurringRevenue '{"limit":500}')
check "view: active subscriptions" "$ACTIVE" "$(echo "$V" | python3 -c 'import json,sys; print(sum(r["activeSubscriptions"] for r in json.load(sys.stdin)["data"]))')"

if [ -z "$SKIP_ACCOUNT_JOIN" ]; then
  echo "== L3: an account the CRM knows reaches what billing knows =="
  # Accounts exist once a CRM realm's customers have been read; read them.
  kg "MATCH (b:OdooBook)-[:HAS_CUSTOMER]->(c:OdooCustomer) RETURN count(c) AS n" >/dev/null
  BILLED=$(kg "MATCH (a:CustomerAccount)-[:BILLED_AS]->(c:BillingCustomer) RETURN count(DISTINCT a) AS n" | n)
  if [ "$BILLED" -gt 0 ]; then echo "  ok   accounts joined to a billing customer = $BILLED (non-zero)"
  else echo "  FAIL accounts joined to a billing customer: 0 — the cross-realm join is not there"; fail=1; fi
  # Exactness: every link is the SAME company. Lago's search is a substring match.
  WRONG=$(kg "MATCH (a:CustomerAccount)-[:BILLED_AS]->(c:BillingCustomer) WHERE NOT toLower(c.url) CONTAINS a.accountKey RETURN count(c) AS n" | n)
  check "billing customers linked to an account that is not theirs" "0" "$WRONG"
fi

[ $fail -eq 0 ] && echo "ALL CHECKS PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
