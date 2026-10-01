#!/bin/sh
# relentless-testing for realm-lago's WRITE verbs, against a DISPOSABLE Lago, never the one holding
# the book. Lago keeps what these verbs make: a voided invoice stays voided, a subscription's
# invoices outlive it, and a deleted customer's invoices are still listed. So this script starts its
# own Lago from stack/compose.yml under a separate project on other ports, exercises the verbs there,
# and removes that Lago, volumes included.
#
# It runs the realm's COMPILED methods (dist/api/*.js) with a gateway that sends each verb exactly
# as apis/lago.json declares it, so it proves method, verb and Lago together. It does not go
# through an appliance: the appliance's Lago is the demo's, and these writes cannot be undone there.
#
#   sh tests/verify-writes.sh          (needs Docker and Node; KEEP=1 leaves the disposable Lago up)
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT=lago-verify
PORT="${VERIFY_LAGO_PORT:-3290}"
export LAGO_API_PORT="$PORT" LAGO_FRONT_PORT="${VERIFY_LAGO_FRONT_PORT:-8190}"

compose() { docker compose -p "$PROJECT" -f "$DIR/stack/compose.yml" "$@"; }
[ "$KEEP" = 1 ] || trap 'compose down -v >/dev/null 2>&1' EXIT
compose up -d >/dev/null 2>&1
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")" = 200 ] && break; sleep 5
done
KEY=$(docker run --rm -v "${PROJECT}_lago-state:/state" alpine sh -c '. /state/lago.env; echo $LAGO_ORG_API_KEY')

LAGO="http://127.0.0.1:$PORT/api/v1" KEY="$KEY" SPEC="$DIR/apis/lago.json" DIST="$DIR/dist/api" node - <<'JSEOF'
const fs = require("fs");
const spec = JSON.parse(fs.readFileSync(process.env.SPEC, "utf8"));
const base = process.env.LAGO, key = process.env.KEY;
let bad = 0;
const check = (name, ok, detail = "") => { console.log((ok ? "  ok   " : "  FAIL ") + name + (ok ? "" : `: ${detail}`)); if (!ok) bad++; };

async function http(method, path, body) {
  const r = await fetch(base + path, { method, headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  const json = text ? JSON.parse(text) : null;
  if (!r.ok) { const e = new Error(`${r.status} ${json && json.code}`); e.code = json && json.code; throw e; }
  return json;
}

// A gateway built from the spec, not by hand: each operationId sends its own method and path, with
// path parameters taken from the arguments and the rest as the body, as the appliance does.
const ops = {};
for (const [path, methods] of Object.entries(spec.paths))
  for (const [method, op] of Object.entries(methods)) ops[op.operationId] = { method: method.toUpperCase(), path, params: (op.parameters || []).filter(p => p.in === "path").map(p => p.name) };
const lago = {};
for (const [id, op] of Object.entries(ops)) lago[id] = (args = {}) => {
  let path = op.path; const body = { ...args };
  for (const p of op.params) { path = path.replace(`{${p}}`, encodeURIComponent(args[p])); delete body[p]; }
  return http(op.method, path, op.method === "GET" ? undefined : (Object.keys(body).length ? body : undefined));
};
const gateway = { lago };
const bind = (Klass, fields) => Object.assign(Object.assign(new Klass(), fields), { gateway });
const { LagoCustomer } = require(process.env.DIST + "/customer.js");
const { LagoInvoice } = require(process.env.DIST + "/invoice.js");

(async () => {
  const tag = "verify-" + Date.now();
  // Setup through Lago directly: a plan billed in advance, an add-on, a customer.
  await http("POST", "/plans", { plan: { name: tag, code: tag, interval: "monthly", amount_cents: 10000, amount_currency: "USD", pay_in_advance: true } });
  await http("POST", "/add_ons", { add_on: { name: tag, code: tag, amount_cents: 5000, amount_currency: "USD" } });
  const cust = (await http("POST", "/customers", { customer: { external_id: tag, name: tag, currency: "USD" } })).customer;
  console.log(`== disposable Lago on ${base}, customer ${tag} ==`);

  console.log("-- LagoCustomer.subscribe");
  const customer = bind(LagoCustomer, { id: cust.lago_id, externalId: tag, name: tag });
  const s1 = await customer.subscribe({ planCode: tag, subscriptionId: `${tag}-deal` });
  check("subscription is active on the plan", s1.status === "active" && s1.plan_code === tag, JSON.stringify(s1));
  const s2 = await customer.subscribe({ planCode: tag, subscriptionId: `${tag}-deal` });
  check("the same subscription id returns the same subscription", s2.lago_id === s1.lago_id, `${s1.lago_id} vs ${s2.lago_id}`);
  const subs = (await http("GET", `/subscriptions?external_customer_id=${tag}`)).subscriptions;
  check("so there is exactly one", subs.length === 1, `${subs.length}`);

  console.log("-- LagoInvoice.writeOff");
  const inv = (await http("POST", "/invoices", { invoice: { external_customer_id: tag, currency: "USD", fees: [{ add_on_code: tag, units: 1 }] } })).invoice;
  const invoice = bind(LagoInvoice, { id: inv.lago_id, number: inv.number, paymentStatus: inv.payment_status });
  check("writeOff voids it", (await invoice.writeOff()) === "voided");
  const after = (await http("GET", `/invoices/${inv.lago_id}`)).invoice;
  check("Lago holds it voided", after.status === "voided", after.status);
  let refused = null;
  try { await invoice.writeOff(); } catch (e) { refused = e.code; }
  check("a second write-off is refused, not repeated", refused === "not_voidable", String(refused));
  const paid = bind(LagoInvoice, { id: inv.lago_id, number: inv.number, paymentStatus: "succeeded" });
  let local = null;
  try { await paid.writeOff(); } catch (e) { local = e.message; }
  check("a paid invoice is refused before Lago is asked", /is paid/.test(String(local)), String(local));

  process.exit(bad ? 1 : 0);
})().catch((e) => { console.log("  FAIL " + e.stack); process.exit(1); });
JSEOF
