# Bookkeeping Ledger — MCP Server Spec

Status: **built.** `src/main.mo` implements this spec; it compiles, deploys, and the
accounting invariants below are exercised against a local replica. Opening #12 on the
Prometheus App Store opportunity map (business operations). Not yet deployed to mainnet.

What changed from the original draft, all decided during the build:

- **24 tools, not sixteen** — the draft's own tables listed 20, and the reader grants added
  three more. The count in the prose was simply wrong.
- **Open question 3 is decided: scoped read grants ship in v1** (`grant_reader`,
  `revoke_reader`, `list_readers`). Every reporting tool takes an optional `books` argument
  and authorizes the caller as owner-or-live-reader. Grants are read-only and an expiry is
  mandatory.
- **Open question 1 is decided as recommended**: basis defaults to cash, is selectable at
  `setup_books`, and locks — along with base currency — once the first entry exists.

---

## Why this exists

Money already moves across this store. Invoice Desk settles ckUSDC. The wallets hold
tokens. The DEX apps swap. Subscription Auditor sees the recurring outflows. Dispatch
Scheduler quotes prices that later become invoices. Every one of those is a transaction
record trapped in its own canister.

None of them answers the two questions a business actually has to answer:

1. **What did I earn and spend this period?**
2. **What do I hand my accountant in April?**

That is bookkeeping, and it does not exist anywhere on the store.

The reason bookkeeping is miserable for small operators is data entry — someone has to
transcribe events into books after the fact, and nobody does. That premise dies when the
agent that moved the money is the same agent that writes the entry. **The books get
written because the agent doing the transacting posts as it acts.**

The second reason to build this on-chain rather than anywhere else: an asset account can
be bound to a real ICRC ledger, so **the books can check themselves against the chain.**
QuickBooks cannot verify that your cash account is real. This can. That is `reconcile`,
and it is a first-class tool, not a footnote.

---

## What it will not do

**It never moves money.** Not once, not for convenience. It records. Dispatch Scheduler
set this precedent deliberately — a service carries a price quote and settlement belongs
to Invoice Desk — and it matters more here, because a ledger that can also spend is a
ledger nobody should trust to describe its own spending. There is no transfer tool, no
approve tool, no wallet key. The only ledger call this server ever makes is
`icrc1_balance_of`, and it is read-only.

**It does not file taxes and it is not tax advice.** `tax_summary` produces categorized
totals with the rules it applied stated out loud. A human or their accountant decides what
that means. The tool description says so, and so does every response it returns.

**It does not guess a category.** An expense an agent cannot classify posts to `6900
Uncategorized` and surfaces in the `review` sweep. Silently binning an ambiguous charge
into "Marketing" produces books that are confidently wrong, which is worse than books that
are visibly incomplete.

**It does not compute capital gains in v1.** See [Open questions](#open-questions) — this
is named as out of scope rather than half-done, because the half-done version produces
numbers someone might file.

---

## Data model

Motoko sketch, following the `subscription-auditor` idiom: `Map` from `mo:map`, dates as
days since the Unix epoch in UTC, money as minor units, everything partitioned per
principal.

```motoko
type AccountKind = { #asset; #liability; #equity; #income; #expense };

type LinkedLedger = {
  ledger : Text;            // ICRC ledger canister id
  account : Principal;      // whose balance this account mirrors
  subaccount : ?Blob;
  lastChainMinor : ?Nat;    // last observed on-chain balance
  lastReconciledAt : ?Int;  // ns
};

type Account = {
  id : Nat;
  owner : Principal;
  code : Text;              // "1000", "4000" — accountant-legible, stable sort key
  name : Text;
  kind : AccountKind;
  parent : ?Nat;
  linked : ?LinkedLedger;   // only meaningful on #asset accounts
  archived : Bool;
  createdAt : Int;
};

type Side = { #debit; #credit };

type Line = {
  account : Nat;
  side : Side;
  minor : Nat;              // minor units of the books' base currency
  memo : ?Text;
};

// A token movement's exchange rate, frozen at post time. Never looked up later.
type Rate = {
  symbol : Text;            // "ICP"
  units : Nat;              // how much token moved, in the token's minor units
  minorPerUnit : Nat;       // base-currency minor units per whole token
  source : Text;            // "ratestream", "manual"
  at : Int;                 // ns, when the rate was observed
};

type Ref = {
  source : Text;            // "invoice-desk" | "subscription-auditor" | "wallet" | "manual"
  id : Text;                // "inv-17", a tx index, a subscription id
  canister : ?Text;
};

type Entry = {
  seq : Nat;                // immutable, gapless per owner
  owner : Principal;
  day : Int;                // accounting date, days since epoch UTC
  memo : Text;
  lines : [Line];           // >= 2, balanced
  rate : ?Rate;             // present iff the movement was token-denominated
  ref : ?Ref;
  reverses : ?Nat;          // this entry reverses seq N
  reversedBy : ?Nat;        // this entry was reversed by seq N
  postedAt : Int;           // ns, when it hit the canister
};

type Basis = { #cash; #accrual };

type Books = {
  owner : Principal;
  baseCurrency : Text;          // "USD"
  fiscalYearStartMonth : Nat;   // 1-12
  basis : Basis;
  closedThrough : ?Int;         // days since epoch; nothing posts on or before this
  createdAt : Int;
};

// A scoped, expiring, READ-ONLY grant — open question 3, decided and built.
type ReaderGrant = {
  owner : Principal;
  reader : Principal;
  expiresDay : Int;
  note : ?Text;
  grantedAt : Int;
};

let books : Map.Map<Principal, Books> = Map.new();
let accountsById : Map.Map<Nat, Account> = Map.new();
let accountIdsByOwner : Map.Map<Principal, [Nat]> = Map.new();

// Keyed "<owner>#<seq>", NOT by a global seq. The draft had `Map<Nat, Entry>`,
// which collides the moment two owners both have an entry #1 — invariant 4 makes
// `seq` per-owner, so the key has to be too.
let entriesByKey : Map.Map<Text, Entry> = Map.new();
let entrySeqsByOwner : Map.Map<Principal, [Nat]> = Map.new();
let nextSeqByOwner : Map.Map<Principal, Nat> = Map.new();

let grantsByKey : Map.Map<Text, ReaderGrant> = Map.new(); // "<owner>#<reader>"
let grantKeysByOwner : Map.Map<Principal, [Text]> = Map.new();
```

### Invariants

These are enforced in the canister, not suggested — the Dispatch Scheduler rule that
availability is checked at `book` time, applied to accounting.

1. **Every entry balances.** `sum(debit.minor) == sum(credit.minor)`, or `post_entry`
   fails loudly. This is the whole point of double-entry and it is free to enforce.
2. **Entries are never mutated and never deleted.** A mistake is corrected by
   `reverse_entry`, which posts a mirrored entry and links the two. Deletable books are
   worthless books. (Same principle as `cancel_booking` never removing a booking.)
3. **Nothing posts into a closed period.** If `day <= closedThrough`, the post is refused
   with the close date in the error. Back-dating into filed books is the failure mode this
   prevents.
4. **`seq` is gapless per owner.** A gap means data loss. Gapless is what makes the ledger
   auditable by someone who does not trust it.
5. **Every amount is base-currency minor units.** A token movement carries a `Rate` frozen
   at post time. "3 ICP" is not a number the books can use in November.
6. **Accounts that have ever been posted to are archived, never deleted.** Referential
   integrity of historical entries beats a tidy account list.
7. **Basis and base currency lock once the first entry exists** (open question 1, decided).
   The error names how many entries are in the way.

**One thing the draft missed, found while building `balance_sheet`.** Income and expense
accounts are never closed out to equity in v1, so the accounting equation cannot hold from
the stored accounts alone — `assets = liabilities + equity` is only true once *retained
earnings* is added, computed as all income less all expenses up to the report date. The
balance sheet emits it as a synthetic `3900 Retained Earnings (computed)` line and then
asserts the equation out loud. Without that line every balance sheet would have reported
itself as broken.

### Default chart of accounts

Seeded by `setup_books` so the server is usable on first call, fully editable after.

| Code | Account | Kind |
|------|---------|------|
| 1000 | Cash — ckUSDC | asset |
| 1010 | Cash — other tokens | asset |
| 1100 | Accounts Receivable | asset |
| 1500 | Equipment | asset |
| 2000 | Accounts Payable | liability |
| 3000 | Owner's Equity | equity |
| 3100 | Owner's Draw | equity |
| 4000 | Service Revenue | income |
| 4100 | Product Revenue | income |
| 5000 | Cost of Services | expense |
| 6000 | Software & Subscriptions | expense |
| 6100 | Fees — network & payment | expense |
| 6200 | Marketing | expense |
| 6900 | Uncategorized | expense |

`7000 Realized Gain/Loss on Token` is deliberately **not** seeded — see open question 2.

---

## Tools

24 tools, `verb_noun` naming, all free (no metering — matching Subscription Auditor;
see [Metering](#metering)).

### Setup

| Tool | What it does |
|------|--------------|
| `setup_books` | Base currency, fiscal year start month, cash or accrual basis. Seeds the default chart of accounts. Idempotent — refuses if books already exist, pointing at `update_books` |
| `add_account` | Add an account: code, name, kind, optional parent |
| `list_accounts` | The chart of accounts with current balances, optionally including archived |
| `archive_account` | Retire an account. Refuses if it has a non-zero balance, with the balance in the error |
| `link_account` | Bind an asset account to an ICRC ledger + account + optional subaccount, so `reconcile` can check it |

### Posting

| Tool | What it does |
|------|--------------|
| `post_entry` | The core. Date, memo, 2+ lines. Refuses unless debits equal credits and the period is open |
| `record_invoice` | Convenience: given an Invoice Desk invoice, post the revenue side per the books' basis |
| `record_payment` | Settle receivable against a cash account, or (cash basis) recognize the income now |
| `record_expense` | The common one-in-two-out case: amount, category account, paid-from account |
| `get_entry` | One entry in full, with its reversal links and source reference |
| `list_entries` | Filter by account, date range, source, or counterparty; newest first |
| `reverse_entry` | Post a mirrored entry that cancels an earlier one. Requires a reason |

### Reporting

| Tool | What it does |
|------|--------------|
| `profit_and_loss` | Income and expense totals for a period, with prior-period comparison |
| `balance_sheet` | Assets, liabilities, equity as of a date. Asserts the accounting equation holds |
| `trial_balance` | Every account's debit/credit totals and the proof they're equal — the accountant's check |
| `account_ledger` | One account's entries with a running balance |
| `reconcile` | Book balance vs. live on-chain balance for a linked account, with the difference and the entries that would explain it |
| `tax_summary` | Categorized deductible totals and quarterly estimates, with the rules applied stated in the response |
| `review` | The sweep, in the shape of Subscription Auditor's `audit`: unbalanced drafts, `Uncategorized` postings, unreconciled linked accounts, receivables past due, periods ready to close |
| `close_period` | Lock everything on or before a date. Refuses if the trial balance does not balance or `Uncategorized` is non-zero |

### Schemas for the three that carry the design

**`post_entry`**

```jsonc
{
  "day": "2026-08-24",              // ISO date, UTC. Optional; defaults to today
  "memo": "Invoice 17 — Fairview HOA quarterly service",
  "lines": [                        // 2..64 lines, must balance
    { "account": "1100", "debit":  45000, "memo": "A/R Fairview" },
    { "account": "4000", "credit": 45000 }
  ],
  "rate": {                         // optional; required if the movement was in token
    "symbol": "ICP", "units": 300000000,
    "minor_per_unit": 1180, "source": "ratestream"
  },
  "ref": { "source": "invoice-desk", "id": "inv-17" }
}
```
Amounts are base-currency minor units (cents) as integers — never floats, never a decimal
string. Accounts are addressed by `code`, not internal id, so an agent can post without a
lookup round-trip. Each line carries exactly one of `debit` or `credit`.

**`reconcile`**

```jsonc
{ "account": "1000", "as_of": "2026-08-24" }
```
Returns book balance, live `icrc1_balance_of` result, the signed difference, when it was
last reconciled, and the entries posted since — so the answer to "where did the $340 go"
is in the same response as the $340. If the account is not linked, it says so and points
at `link_account` rather than returning a hollow zero.

**`close_period`**

```jsonc
{ "through": "2026-06-30", "confirm": true }
```
Refuses unless the trial balance balances and `6900 Uncategorized` is zero, listing what
blocks it. `confirm` is required because closing is the one irreversible operation on the
server — reopening a period is deliberately not a tool, since "unfiled my taxes" is not a
thing an agent should be able to do on its own.

---

## Composition with what's already shipped

| Source | Feeds | How |
|--------|-------|-----|
| **Invoice Desk** `kx2vm-6qaaa-aaaao-qqbca-cai` | Revenue, A/R | `record_invoice` on send, `record_payment` on `verify_payment` |
| **Subscription Auditor** `yi33e-byaaa-aaaab-agz4q-cai` | Recurring expense | `record_expense` per renewal, tagged `ref.source = "subscription-auditor"` |
| **Dispatch Scheduler** `swvip-jqaaa-aaaam-qjgdq-cai` | Nothing directly | Bookings become invoices, invoices become entries. Deliberately one hop away |
| **RateStream** | Token rates | `rate.source = "ratestream"` at post time |
| **Wallets / DEX** | Cash balances | `link_account` + `reconcile` |

This is the map's business-ops opening with the **shortest integration distance** — two
already-shipped servers generate its input on day one.

---

## Privacy model

Same as Subscription Auditor, same caveats, stated the same way. Data is partitioned per
principal; tool calls require `x-api-key`; each key is bound to the principal that minted
it; every read and write touches only that principal's partition.

Private *to your principal*, **not encrypted against node providers.** Books name
customers and amounts. That is a real disclosure surface on a public chain and it needs to
be in the README in the same blunt terms the Auditor uses about card numbers — a business
that would not publish its customer list should know what it is putting here before it
posts entry #1.

---

## Metering

Free for v1, `payment: null`, matching Subscription Auditor's nine-free-tools model.

The argument for metering the reports (`profit_and_loss`, `tax_summary` are the expensive
computation) is real but premature: an unused ledger has no reports to run, and the
adoption cost of a paywall on the tool that demonstrates the value is worse than the cycle
cost of computing it. Revisit once there are books worth reporting on.

---

## Open questions

These are the three that cannot be deferred past v1, plus two that can.

**1. Cash or accrual — and can it change?**
Accrual books income when the invoice is sent; cash books it when payment clears. It
changes what `record_invoice` does. Recommendation: **default cash**, since the target user
is a small operator whose taxes are cash-basis anyway, with `accrual` selectable at
`setup_books`. The hard part is that switching basis after entries exist requires restating
every open receivable — I would make `basis` immutable after the first entry and say so in
the error, rather than build a restatement engine nobody asked for.

**2. Cost basis and realized gains — out of v1, but name the boundary.**
Paid 3 ICP in June, swapped it in September: there is a real gain or loss, and it is
taxable. Doing this properly needs lot tracking and a FIFO/specific-identification choice —
a genuine accounting engine, not a feature. v1 records the frozen `Rate` on every token
entry, which is *exactly the data* a later gains engine needs, and does not pretend to
compute the gain. `7000 Realized Gain/Loss` is left unseeded so nothing posts to it by
accident. This is the thing that makes crypto bookkeeping actually hard and the version
that half-does it produces numbers someone might file.

**3. Can an accountant read the books? — DECIDED, and built.**
Scoped read grants ship in v1: `grant_reader` takes a principal and a **mandatory** expiry,
and every reporting tool accepts an optional `books` argument authorizing the caller as
owner-or-live-reader. A grant never permits posting, reversing, closing, or granting onward.
This was chosen over waiting for the **Agent Identity & Delegation Registry** (opening #10)
because "export to my accountant" is the moment the product proves itself, and blocking it
on an unbuilt server means it never happens. Revisit when the registry exists — a delegation
with a purpose and a spend cap is strictly better than a boolean read flag.

**4. Multi-currency.** Deferred. Base currency USD, ckUSDC ≈ USD, everything else lands
through a frozen rate. Revisit if anyone actually keeps books in something else.

**5. Attachments.** Receipts and invoices as evidence want **Document & File Storage**
(opening #12). Until then `Ref` points at the source canister, which is better than a
filename anyway.
