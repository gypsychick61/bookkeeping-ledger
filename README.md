# Bookkeeping Ledger — MCP Server

A double-entry ledger your agent posts to as money moves. Entries must balance or they are
refused. Nothing is ever edited or deleted, only reversed. And a cash account bound to an
ICRC ledger can be checked against the chain.

Motoko canister on the Internet Computer, exposed over MCP at `/mcp`. Design notes and the
decisions behind all of this are in [SPEC.md](SPEC.md).

## Why this exists

Money already moves across this store. Invoice Desk settles ckUSDC. The wallets hold tokens.
Subscription Auditor sees the recurring outflows. Every one of those is a transaction record
trapped in its own canister, and none of them answers the two questions a business actually
has to answer: what did I earn and spend this period, and what do I hand my accountant in
April.

Bookkeeping is miserable for small operators for exactly one reason — someone has to
transcribe events into books after the fact, and nobody does. That premise dies when the
agent that moved the money is the same agent that writes the entry.

The second reason to build it here rather than anywhere else: an asset account can be bound
to a real ICRC ledger, so **the books can check themselves against the chain.** QuickBooks
cannot verify that your cash account is real. This can.

## What it will not do

**It never moves money.** Not once, not for convenience. There is no transfer tool, no
approve tool, and no wallet key. The only ledger call this canister ever makes is
`icrc1_balance_of`, and it is read-only. A ledger that can also spend is a ledger nobody
should trust to describe its own spending.

**It does not file taxes and it is not tax advice.** `tax_summary` returns categorized
totals plus an explicit list of the rules it applied, so a human or their accountant can
decide what they mean.

**It does not guess a category.** An expense an agent cannot classify posts to `6900
Uncategorized` and surfaces in `review`. Silently binning an ambiguous charge into
"Marketing" produces books that are confidently wrong, which is worse than books that are
visibly incomplete.

**It does not compute capital gains.** Entries carry the exchange rate frozen at post time —
exactly the data a gains engine needs — and v1 does not pretend to do the calculation. The
half-done version produces numbers someone might file.

## The rules the canister enforces

These are checked in the canister, not suggested in a doc.

1. **Every entry balances.** Debits equal credits or `post_entry` fails with the difference
   in the error.
2. **Entries are never mutated or deleted.** `reverse_entry` posts a mirrored correction and
   links both directions. A reversal posts *today*, never back into a closed period.
3. **Nothing posts into a closed period**, including corrections.
4. **`seq` is gapless per owner.** A gap would mean data loss; gapless is what makes the
   ledger auditable by someone who does not trust it.
5. **Every amount is base-currency minor units** — `4500` means `$45.00`. A fractional cent
   is refused rather than rounded, because that rounding is a decision nobody asked this
   server to make.
6. **Accounts that hold a balance cannot be archived**, and archived accounts cannot be
   posted to. Historical entries keep pointing at them.
7. **Basis and base currency lock once the first entry exists.** Switching cash↔accrual
   afterwards would require restating every open receivable.

## Tools

24 tools, all free.

**Setup** — `setup_books`, `update_books`, `add_account`, `list_accounts`,
`archive_account`, `link_account`

**Posting** — `post_entry`, `record_invoice`, `record_payment`, `record_expense`,
`get_entry`, `list_entries`, `reverse_entry`

**Reporting** — `profit_and_loss`, `balance_sheet`, `trial_balance`, `account_ledger`,
`reconcile`, `tax_summary`, `review`, `close_period`

**Sharing** — `grant_reader`, `revoke_reader`, `list_readers`

`setup_books` seeds a 14-account chart you can edit. `7000 Realized Gain/Loss` is
deliberately *not* seeded, so nothing posts there by accident.

### post_entry

```jsonc
{
  "day": "2026-03-15",
  "memo": "Invoice 17 — Fairview HOA quarterly service",
  "lines": [
    { "account": "1100", "debit":  45000 },
    { "account": "4000", "credit": 45000 }
  ],
  "ref": { "source": "invoice-desk", "id": "inv-17" }
}
```

Accounts are addressed by **code**, not internal id, so an agent can post without a lookup
round-trip. Each line carries exactly one of `debit` or `credit`. Amounts are integers in
minor units.

### reconcile

Book balance vs. live `icrc1_balance_of`, the signed difference, and the entries posted
since the last reconciliation — so the answer to "where did the $340 go" is in the same
response as the $340.

Chain amounts are converted from the ledger's own decimals into the books' cents, and the
conversion is stated in the response. ckUSDC has 6 decimals and the books have 2; comparing
those raw is the obvious way to produce a confidently wrong reconciliation.

### close_period

Refuses while the trial balance does not balance or anything is still in `6900
Uncategorized`, listing exactly what blocks it. Requires `confirm: true`, because reopening
a period is deliberately **not** a tool — "unfiled my taxes" is not something an agent
should be able to do on its own.

## Sharing books with an accountant

Every other server in this lineup is one-principal, one-partition. Real books get handed to
someone in April, so this one has scoped read grants:

```jsonc
grant_reader { "principal": "<accountant>", "expires": "+90", "note": "FY2026 filing" }
```

The reader then passes `books: "<owner-principal>"` to any reporting tool. A grant is
**read-only and always expires** — it never permits posting, reversing, closing, or granting
onward, and there is no way to create one without an end date, because a permission with no
expiry is one nobody revokes.

## Privacy model

Data is partitioned per principal; tool calls require `x-api-key`; each key is bound to the
principal that minted it, and every read and write touches only that principal's partition
unless a reader grant says otherwise.

Private *to your principal*, **not encrypted against node providers.** Books name customers
and amounts. That is a real disclosure surface on a public chain: a business that would not
publish its customer list should know what it is putting here before it posts entry #1.

## Getting an API key

```bash
dfx canister call bookkeeping_ledger create_my_api_key '("my key", vec {})'
```

The returned key goes in the `x-api-key` header. It is shown only once.

## Local development

```bash
mops install
dfx start --background
dfx deploy
```

MCP endpoint: `http://<canister-id>.localhost:4943/mcp` (or `http://127.0.0.1:4943/mcp`
with a `Host: <canister-id>.localhost` header).

`reconcile` is the one tool that needs something else running: locally there is no ckUSDC
ledger, so a linked account returns a clean "could not read ledger metadata" error rather
than a fabricated balance. That error path is worth seeing. To exercise the success path you
need a stub canister answering `icrc1_balance_of`, `icrc1_symbol` and `icrc1_decimals`.

## Mainnet

Not yet deployed. When it is, this section gets the canister id and the ICForge/BYOC notes
that every other server here carries — see [`../README.md`](../README.md) for the pattern,
and remember that the store listing is a BYOC binding refreshed with `byoc register`, not
`update --hash`.
