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

- `apis/` — three Lago operations, vendored and curated, each with what was found by calling
  it: `search_term` is a substring search; `external_customer_id` is exact; the subscription
  listing returns **active only**, and the parameter that widens it cannot be sent (below).
- `types/` — `LagoBooks` (the door, one scope, default `all`), `LagoCustomer`
  (`parents: [BillingCustomer]`, `url` → `hub: CustomerAccount`), `LagoSubscription`,
  `LagoInvoice`, and `LagoInvoiceMetadata` (an invoice's key/values, brought with it).
- `producers/` — the three listings as doors, plus customers by domain and
  subscriptions / invoices by customer.
- `views/` — `LagoUnpaidInvoices` (filterable by payment status and customer),
  `LagoReceivablesByCustomer`, `LagoRecurringRevenue`, `LagoPaymentStatusCounts`. All
  prefixed: view names resolve globally across realms. Views return money in **major units**.
- `tests/verify.sh` — ground truth from Lago itself, then the traversal by the vocabulary's
  labels, then the views, then the account join: non-zero, and every link the same company.
- `stack/` — a disposable Lago in Docker with its first boot automated.
- `seed/load_book.py` — loads the billing part of a product-neutral book.

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

A producer can rename a source field; it cannot compute one. These are absent, not faked:

| Vocabulary | Here | Why |
|---|---|---|
| `amount` in major units | `amountCents`, `amountPaidCents`, `amountDueCents` | Lago speaks integer cents. The views divide; a hand-written query must too. |
| `accountKey` on a billing record | — | It would be the domain out of `url`. Reach the account by `BILLED_AS` instead. |
| `BillingSubscription.interval` | `planCode` | The period is on the plan, which Lago's subscription listing does not inline. Do not annualize `amountCents`. |
| ended subscriptions | active only | Lago returns the rest only for `status[]=…`, and the host's HTTP client refuses a query parameter whose *name* contains `[`. A cancelled subscription is invisible here, so "who churned" cannot be answered from billing yet. |
| `PaymentAttempt` | `LagoInvoiceMetadata` | Lago records attempts only when connected to a payment processor, and exposes them on its paid tier. A business that keeps its own record does so in invoice metadata. Reason from `paymentStatus`. |

## A note on the demo book's dates

Lago stamps an invoice created through its API with today's date, so on the demo stack every
invoice was "issued today" and none is `overdue` by Lago's reckoning. The book's own issue, due
and paid dates travel in each invoice's metadata (`dates`), which is the honest place for a
fact Lago was not allowed to hold. A Lago that issued its own invoices has real dates.
