# realm-lago

Lago, spoken to through its own API, as an Embabel realm — and as the **billing** slot of the
business vocabulary. A customer here *is* a `BillingCustomer`, a subscription a
`BillingSubscription`, an invoice a `BillingInvoice`. The node carries both labels:

```cypher
MATCH (a:CustomerAccount)-[:BILLED_AS]->(c:BillingCustomer)-[:HAS_INVOICE]->(i:BillingInvoice)
WHERE i.paymentStatus <> 'succeeded'
RETURN a.name, i.number, i.amountDueCents / 100.0 AS owed, i.paymentStatus
```

Nothing in that query names Lago, and nothing in this realm names a CRM. Nothing is mirrored:
every traversal reads Lago at query time, so an invoice marked paid in Lago's own UI is gone
from the unpaid list on the next ask. People keep working in Lago; this realm is how the rest
of the business finds out what it knows.

## How an account reaches its billing

Lago has no "company domain". It has a customer `url`, in whatever shape someone typed it.
This realm sends that on **untouched**, twice:

- `LagoCustomer.url` carries `hub: CustomerAccount`, so a Lago customer keys the vocabulary's
  account spine. That includes a customer the CRM has never heard of — which is a finding,
  not an error: somebody is being invoiced that sales does not know about.
- The `BILLED_AS` join asks Lago for an account's domain using its search, which is a
  **substring** match (`stark.com` would also return `notstark.com`). So the join does not
  echo the asked key onto what comes back; it matches each record's own `url` *through the
  spine*. The customer whose url is that account is linked. A stray is not.

Nothing here lowercases, strips `www.` or parses a URL. The spine's `normalize` is the one
definition of "the same account", and a realm that kept a copy of it would drift.

## What's inside

- `apis/` — the Lago operations this realm uses, vendored and curated against Lago v1.53, each
  parameter described by what it was seen to do when called. A query parameter the spec does not
  declare is never sent, so every filter a producer pushes is declared here.
- `types/` — `LagoBooks` (the door, one scope, default `all`), `LagoCustomerSearch` (a search
  by a term, so a customer named in a question costs one call), `LagoCustomer`
  (`parents: [BillingCustomer]`, `url` → `hub: CustomerAccount`), `LagoSubscription`, `LagoPlan`,
  `LagoInvoice`, and `LagoInvoiceMetadata` (an invoice's key/values, brought with it).
- `producers/` — the listings as doors, a search, customers by domain, and subscriptions /
  invoices by customer. Each says which of Lago's filters it sends and which it does not, and why.
- `views/` — `LagoUnpaidInvoices`, `LagoCustomerInvoices` (one customer, by exact name or external
  id), `LagoInvoicesIssued` (a window of issue dates), `LagoReceivablesByCustomer`,
  `LagoRecurringRevenue` (annualized through each plan's interval), `LagoSubscriptionsByStatus`,
  `LagoPaymentStatusCounts`, `LagoCustomers`, `LagoPlanMix`. All prefixed: view names resolve
  globally across realms. Views return money in **major units**, per currency. A customer
  parameter matches the name **exactly**; `customerMatch: contains` is the opt-in for a fragment.
- `tests/verify.sh` — ground truth from Lago itself; then what a narrow question costs (one
  customer, one day, one plan: each must reach Lago as a narrow request, read from the appliance's
  call count and, with `LAGO_CONTAINER` set, from Lago's own request log); then the traversal by
  the vocabulary's labels, then the views, then the account join: non-zero, and every link the
  same company.
- `stack/` — a disposable Lago in Docker with its first boot automated.
- `seed/load_book.py` — loads the billing part of a product-neutral book. `--remove` deletes the
  customers and voids their unpaid invoices, but Lago never deletes a finalized invoice and a PAID
  one cannot be voided — and this realm joins an invoice to its customer by external id, so a
  leftover would rejoin the customer a reload re-creates. Reseeding from nothing is a fresh Lago:
  recreate its volumes, then load.

## What is sent to Lago, and what a question costs

A filter on a fetched node is sent to Lago as a query parameter when Lago applies it **exactly**;
anything else is applied by the graph after the read. Pages are 200 records, the largest page
every Lago release accepts.

| Question | Sent to Lago | Calls |
|---|---|---|
| one customer by external id | `customers?external_id=` | 1 |
| one customer by name (`LagoCustomerSearch`, `LagoCustomerInvoices`) | `customers?search_term=`, then `invoices?external_customer_id=` | 2 |
| one customer's invoices, subscriptions | `external_customer_id=` | 1 each |
| invoices by payment status, currency, type, overdue, lost dispute, amount range | `payment_status=`, `currency=`, `invoice_type=`, `payment_overdue=`, `payment_dispute_lost=true`, `amount_from=`/`amount_to=` | one page per 200 matching |
| invoices issued in a window (bare `YYYY-MM-DD` bounds, `>=`, `<=`, `=`) | `issuing_date_from=`/`issuing_date_to=` | one page per 200 in the window |
| the latest invoices (`ORDER BY issuedOn DESC LIMIT n`) | Lago's own order, newest issued first | the pages holding n |
| subscriptions by plan, currency, external id; by status (every-status door) | `plan_code=`, `currency=`, `external_id=`, `status[]=` | one page per 200 |
| how many customers / subscriptions (filtered as above) | Lago's `meta.total_count` | 1 |

Not sent, on purpose: a customer's **name** (Lago's only text filter is a substring search over
several fields, a superset — so a name goes through `LagoCustomerSearch`, whose edge says it is a
search); `paymentStatus IN [...]` / `<> 'succeeded'` and every invoice **count** (Lago caches an
invoice list's total for up to 30 minutes under a key that leaves array filters out, so the total
can be another question's); `disputeLost = false` (Lago reads the text `false` as true). Each
producer lists the rest.

Cache windows follow how records change: invoices two minutes (a payment status changes the moment
someone marks it paid), subscriptions five, customers ten, plans an hour. A window is per read, not
per record, so it is set by the most volatile thing the read holds.

## Working on what billing finds

`LagoCustomer` and `LagoInvoice` carry methods, written in TypeScript in `src/api/`, each calling
one of two write verbs in `apis/lago.json`. Each file there is a gateway namespace named after
it, `lago-customer.ts` as `lago_customer`. The `lago_` matters: a namespace that two installed
realms both contribute is withdrawn from both, and a CRM realm has a customer too.

| Type | Method | Does |
|---|---|---|
| `LagoCustomer` | `subscribe({planCode, subscriptionId, name?, startsAt?})` | starts billing on a plan; the same `subscriptionId` again returns the subscription already there |
| `LagoInvoice` | `writeOff()` | voids an unpaid invoice; final, and refused for a paid one before Lago is asked |

Read with `gateway.cypher.query`, bind a row with `state.set`, and call the method on
`state.get(...)`. Each verb declares `x-embabel-effect`: what it changes, whether it can be undone,
and what identifies a repeat. Both are `sensitive`, because both move money, so an agent asks a
person before either even when its authority lets it act.

**No payment reminders.** Lago's own reminder, the payment request, is a paid feature, and the open
source edition refuses it (`feature_unavailable`). Chasing an invoice goes through the CRM or the
support desk instead: a note and a follow-up on the customer, or a reply on their conversation.

`tests/verify-writes.sh` proves both methods against a disposable Lago it starts and removes,
never the one holding the book: a void cannot be undone, and a subscription's invoices outlive it.
`verify.sh` runs it with `VERIFY_WRITES=1`.

## Setup

1. **realm-business-vocabulary installed first.** It declares the billing types and the
   `CustomerAccount` spine. A realm cannot yet declare that it needs another.
2. **A host with realm-declared spines.** `hub: CustomerAccount` and the `BILLED_AS` join need
   one; on an older host the realm loads and the account join returns nothing.
3. **`LAGO_API_KEY`** in the appliance's environment: an organization API key (Lago:
   Developers → API keys). The demo stack writes one to its state volume as `LAGO_ORG_API_KEY`.
4. **The server URL** in `apis/lago.json` is where Lago's API is *as the appliance reaches it*
   (`http://host.docker.internal:3200/api/v1` for the demo stack). A real install edits it.

## What the vocabulary asks for and this realm cannot yet give

A producer can rename a source field or compute from the fields of one record. These are absent,
not faked:

| Vocabulary | Here | Why |
|---|---|---|
| `accountKey` on a billing record | — | It would be the domain out of `url`. Reach the account by `BILLED_AS` instead. |
| `BillingInvoice.paidOn` | — | Open-source Lago records no payment, so it has no paid date. A migrated book's own paid date is in the invoice's `dates` metadata. |
| `BillingSubscription.interval` | `ON_PLAN` → `LagoPlan.interval` | The period is on the plan, which Lago's subscription listing does not inline. `LagoRecurringRevenue` annualizes through it. |
| `PaymentAttempt` | `LagoInvoiceMetadata` | Lago records attempts only when connected to a payment processor, and exposes them on its paid tier. A business that keeps its own record does so in invoice metadata. Reason from `paymentStatus`. |

Money is in both units: Lago's integer cents (`amountCents`, `amountDueCents`, …) and the
vocabulary's major units (`amount`, `amountDue`, …), computed per record. Ended subscriptions are
reachable by `HAS_ANY_SUBSCRIPTION` (Lago's `status[]`); a bare `MATCH (s:BillingSubscription)`
means the active ones.

## Two clocks: Lago's dates and the business's

Every date Lago holds is Lago's: `issuedOn`, `dueOn`, `overdue`, `customerSince` and `createdAt`
say when something happened **in Lago**. Lago stamps an invoice created through its API with
today's date, so an invoice migrated from another system was "issued" the day it was loaded, falls
due `netPaymentTerm` days later, and is not `overdue` by Lago's reckoning however late the book
says it is. The book's own issue, due and paid dates travel in each invoice's metadata (`dates`:
`issued=…;due=…;paid=…`), which is the honest place for a fact Lago was not allowed to hold, and a
subscription keeps the business's start as `subscriptionAt`. An invoice Lago generated itself, from
a subscription's billing period, has real dates and no metadata. The window parameters of the views
are Lago's issue dates.
