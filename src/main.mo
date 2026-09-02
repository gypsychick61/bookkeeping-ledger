import Map "mo:map/Map";
import { thash; phash; nhash } "mo:map/Map";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Nat32 "mo:base/Nat32";
import Nat8 "mo:base/Nat8";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Error "mo:base/Error";
import Json "mo:json";
import HttpTypes "mo:http-types";

import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import SrvTypes "mo:mcp-motoko-sdk/server/Types";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";

shared ({ caller = deployer }) persistent actor class McpServer() = self {

  // --- BOOKKEEPING DATA MODEL ---
  //
  // Double-entry, and the "double" is enforced rather than encouraged: an entry
  // that does not balance is refused at the door. That single rule is what keeps
  // books from drifting into nonsense one convenient shortcut at a time.
  //
  // Three things are deliberate and worth stating before the types:
  //
  //   Money is ALWAYS base-currency minor units as an integer. Cents, not
  //   dollars. Never a float, never "12.99". A token movement carries a Rate
  //   frozen at post time, because "3 ICP" is not a number the books can use in
  //   November.
  //
  //   Entries are never mutated and never deleted. A mistake is corrected by a
  //   reversing entry that links both directions. Deletable books are worthless
  //   books — the whole value of a ledger is that someone who does not trust you
  //   can still audit it.
  //
  //   Dates are days since the Unix epoch in UTC. An accounting date is a date,
  //   not an instant; which hour a transaction landed is not something the books
  //   should pretend to know.

  type AccountKind = { #asset; #liability; #equity; #income; #expense };

  // Binds an asset account to a real ICRC ledger so `reconcile` can check the
  // books against the chain. This is the thing no off-chain ledger can do.
  type LinkedLedger = {
    ledger : Text; // ICRC ledger canister id
    account : Principal; // whose balance this account mirrors
    subaccount : ?Blob;
    lastChainMinor : ?Nat; // last observed on-chain balance, chain minor units
    lastReconciledAt : ?Int; // ns
  };

  type Account = {
    id : Nat;
    owner : Principal;
    code : Text; // "1000", "4000" — accountant-legible, stable sort key
    name : Text;
    kind : AccountKind;
    parent : ?Nat;
    linked : ?LinkedLedger; // only meaningful on #asset accounts
    archived : Bool;
    createdAt : Int;
  };

  type Side = { #debit; #credit };

  type Line = {
    account : Nat;
    side : Side;
    minor : Nat; // minor units of the books' base currency
    memo : ?Text;
  };

  // A token movement's exchange rate, frozen at post time. Never looked up later.
  type Rate = {
    symbol : Text;
    units : Nat; // how much token moved, in the token's minor units
    minorPerUnit : Nat; // base-currency minor units per whole token
    source : Text; // "ratestream", "manual"
    at : Int;
  };

  type Ref = {
    source : Text; // "invoice-desk" | "subscription-auditor" | "wallet" | "manual"
    id : Text;
    canister : ?Text;
  };

  type Entry = {
    seq : Nat; // immutable, gapless per owner
    owner : Principal;
    day : Int; // accounting date, days since epoch UTC
    memo : Text;
    lines : [Line]; // >= 2, balanced
    rate : ?Rate;
    ref : ?Ref;
    reverses : ?Nat;
    reversedBy : ?Nat;
    postedAt : Int;
  };

  type Basis = { #cash; #accrual };

  type Books = {
    owner : Principal;
    baseCurrency : Text;
    fiscalYearStartMonth : Nat; // 1-12
    basis : Basis;
    closedThrough : ?Int; // days since epoch; nothing posts on or before this
    createdAt : Int;
  };

  // A scoped, expiring, READ-ONLY grant. This is how books reach an accountant
  // in April without handing over the keys. A grant never permits posting, and
  // it always expires — a permission with no end date is one nobody revokes.
  type ReaderGrant = {
    owner : Principal;
    reader : Principal;
    expiresDay : Int;
    note : ?Text;
    grantedAt : Int;
  };

  var nextAccountId : Nat = 1;

  let books : Map.Map<Principal, Books> = Map.new();
  let accountsById : Map.Map<Nat, Account> = Map.new();
  let accountIdsByOwner : Map.Map<Principal, [Nat]> = Map.new();

  // Entries are keyed by "<owner>#<seq>" rather than a global id, because `seq`
  // is gapless PER OWNER — a gap means data loss, and gapless is what makes the
  // ledger auditable by someone who does not trust it.
  let entriesByKey : Map.Map<Text, Entry> = Map.new();
  let entrySeqsByOwner : Map.Map<Principal, [Nat]> = Map.new();
  let nextSeqByOwner : Map.Map<Principal, Nat> = Map.new();

  let grantsByKey : Map.Map<Text, ReaderGrant> = Map.new(); // "<owner>#<reader>"
  let grantKeysByOwner : Map.Map<Principal, [Text]> = Map.new();

  // Ledger metadata (symbol, decimals) cached per ledger; it only changes if a
  // ledger is replaced, which is not a thing that happens quietly.
  transient let ledgerMeta : Map.Map<Text, (Text, Nat)> = Map.new();

  // Thresholds the review sweep reasons with. Boring numbers, stated out loud in
  // the tool description so nobody has to guess.
  transient let staleReconcileDays : Int = 30;
  transient let receivableOverdueDays : Int = 45;

  // The seeded chart of accounts. Usable on the first call, fully editable after.
  // 7000 Realized Gain/Loss is deliberately NOT seeded — v1 records the frozen
  // rate on token entries and does not pretend to compute a gain, so nothing
  // should be able to post there by accident.
  transient let defaultChart : [(Text, Text, AccountKind)] = [
    ("1000", "Cash — ckUSDC", #asset),
    ("1010", "Cash — other tokens", #asset),
    ("1100", "Accounts Receivable", #asset),
    ("1500", "Equipment", #asset),
    ("2000", "Accounts Payable", #liability),
    ("3000", "Owner's Equity", #equity),
    ("3100", "Owner's Draw", #equity),
    ("4000", "Service Revenue", #income),
    ("4100", "Product Revenue", #income),
    ("5000", "Cost of Services", #expense),
    ("6000", "Software & Subscriptions", #expense),
    ("6100", "Fees — network & payment", #expense),
    ("6200", "Marketing", #expense),
    ("6900", "Uncategorized", #expense),
  ];

  transient let uncategorizedCode : Text = "6900";
  transient let receivableCode : Text = "1100";
  transient let defaultCashCode : Text = "1000";
  transient let defaultIncomeCode : Text = "4000";

  // --- MCP SERVER PLUMBING ---

  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  let appContext : McpTypes.AppContext = State.init([]);
  let authContext : AuthTypes.AuthContext = AuthState.initApiKey(deployer);

  Cleanup.startCleanupTimer<system>(appContext);
  AuthCleanup.startCleanupTimer<system>(authContext);

  transient let beaconContext : Beacon.BeaconContext = Beacon.init(
    Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai"),
    ?(15 * 60),
  );
  Beacon.startTimer<system>(beaconContext);

  // --- ICRC LEDGER READS ---
  //
  // Read-only, and the ONLY ledger call this canister ever makes is
  // icrc1_balance_of. There is no transfer, no approve, and no wallet key here.
  // A ledger that can also spend is a ledger nobody should trust to describe its
  // own spending.

  transient let defaultLedger : Text = "xevnm-gaaaa-aaaar-qafnq-cai"; // ckUSDC

  type LedgerAccount = { owner : Principal; subaccount : ?Blob };

  func ledgerOf(id : Text) : actor {
    icrc1_balance_of : (LedgerAccount) -> async Nat;
    icrc1_symbol : () -> async Text;
    icrc1_decimals : () -> async Nat8;
  } {
    actor (id);
  };

  // --- CALENDAR MATH ---
  //
  // Days are days-since-epoch; the civil <-> days conversion is Howard Hinnant's
  // algorithm, which relies on division truncating toward zero exactly as
  // Motoko's Int division does.

  transient let nanosPerDay : Int = 86_400_000_000_000;

  func floorDiv(a : Int, b : Int) : Int {
    let q = a / b;
    if ((a % b != 0) and ((a < 0) != (b < 0))) q - 1 else q;
  };

  func floorMod(a : Int, b : Int) : Int { a - floorDiv(a, b) * b };

  func daysFromCivil(y0 : Int, m : Int, d : Int) : Int {
    let y = if (m <= 2) y0 - 1 else y0;
    let era = floorDiv(y, 400);
    let yoe = y - era * 400;
    let mp = floorMod(m + 9, 12);
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468;
  };

  func civilFromDays(z0 : Int) : (Int, Int, Int) {
    let z = z0 + 719468;
    let era = floorDiv(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if (mp < 10) mp + 3 else mp - 9;
    (if (m <= 2) y + 1 else y, m, d);
  };

  func today() : Int { floorDiv(Time.now(), nanosPerDay) };

  func isLeap(y : Int) : Bool {
    (floorMod(y, 4) == 0 and floorMod(y, 100) != 0) or floorMod(y, 400) == 0;
  };

  func daysInMonth(y : Int, m : Int) : Int {
    if (m == 2) { if (isLeap(y)) 29 else 28 } else if (m == 4 or m == 6 or m == 9 or m == 11) 30 else 31;
  };

  func pad2(n : Int) : Text {
    let a = Int.abs(n);
    if (a < 10) "0" # Nat.toText(a) else Nat.toText(a);
  };

  func fmtDate(days : Int) : Text {
    let (y, m, d) = civilFromDays(days);
    Int.toText(y) # "-" # pad2(m) # "-" # pad2(d);
  };

  // The first day of the fiscal year that `day` falls in.
  func fiscalYearStart(day : Int, startMonth : Nat) : Int {
    let (y, m, _) = civilFromDays(day);
    let sm : Int = if (startMonth < 1 or startMonth > 12) 1 else startMonth;
    if (m >= sm) daysFromCivil(y, sm, 1) else daysFromCivil(y - 1, sm, 1);
  };

  func addMonths(day : Int, n : Int) : Int {
    let (y, m, d) = civilFromDays(day);
    let total = (y * 12 + (m - 1)) + n;
    let ny = floorDiv(total, 12);
    let nm = floorMod(total, 12) + 1;
    let maxD = daysInMonth(ny, nm);
    daysFromCivil(ny, nm, if (d > maxD) maxD else d);
  };

  // --- MONEY FORMATTING ---
  //
  // Base-currency minor units are cents: two decimal places, always. The books
  // are kept in one currency (see SPEC open question 4) and everything else
  // arrives through a frozen rate.

  func fmtMinor(v : Int, cur : Text) : Text {
    let neg = v < 0;
    let a = Int.abs(v);
    (if (neg) "-" else "") # cur # " " # Int.toText(a / 100) # "." # pad2(a % 100);
  };

  // "a income account" reads like a typo in an error someone is already annoyed by.
  func aKind(k : AccountKind) : Text {
    switch (k) {
      case (#asset) "an asset";
      case (#liability) "a liability";
      case (#equity) "an equity";
      case (#income) "an income";
      case (#expense) "an expense";
    };
  };

  // Percent with at most two decimals and no trailing zero noise: 25, 7.5, 33.33.
  func fmtPct(v : Float) : Text {
    let scaled = Float.toInt(v * 100.0 + 0.5);
    let whole = scaled / 100;
    let frac = Int.abs(scaled % 100);
    if (frac == 0) Int.toText(whole)
    else if (frac % 10 == 0) Int.toText(whole) # "." # Nat.toText(frac / 10)
    else Int.toText(whole) # "." # pad2(frac);
  };

  func kindText(k : AccountKind) : Text {
    switch (k) {
      case (#asset) "asset";
      case (#liability) "liability";
      case (#equity) "equity";
      case (#income) "income";
      case (#expense) "expense";
    };
  };

  func basisText(b : Basis) : Text {
    switch (b) { case (#cash) "cash"; case (#accrual) "accrual" };
  };

  func sideText(s : Side) : Text {
    switch (s) { case (#debit) "debit"; case (#credit) "credit" };
  };

  // Debit-normal kinds report a positive balance when debits exceed credits;
  // credit-normal kinds are the other way round. Getting this backwards is how a
  // P&L ends up showing negative revenue.
  func isDebitNormal(k : AccountKind) : Bool {
    switch (k) {
      case (#asset) true;
      case (#expense) true;
      case (#liability) false;
      case (#equity) false;
      case (#income) false;
    };
  };

  func normalized(k : AccountKind, debitMinusCredit : Int) : Int {
    if (isDebitNormal(k)) debitMinusCredit else -debitMinusCredit;
  };

  // --- TEXT PARSING ---

  func lower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char { Char.fromNat32(if (c >= 'A' and c <= 'Z') Char.toNat32(c) + 32 else Char.toNat32(c)) });
  };

  func digitsToNat(t : Text) : ?Nat {
    var n : Nat = 0;
    var any = false;
    for (c in t.chars()) {
      if (not Char.isDigit(c)) return null;
      any := true;
      n := n * 10 + Nat32.toNat(Char.toNat32(c) - 48);
    };
    if (any) ?n else null;
  };

  func splitParts(t : Text, sep : Char) : [Text] {
    let out = Buffer.Buffer<Text>(4);
    var cur = "";
    for (c in t.chars()) {
      if (c == sep) { out.add(cur); cur := "" } else { cur #= Char.toText(c) };
    };
    out.add(cur);
    Buffer.toArray(out);
  };

  func parseDate(t : Text) : ?Int {
    let parts = splitParts(t, '-');
    if (parts.size() != 3) return null;
    let ?y = digitsToNat(parts[0]) else return null;
    let ?m = digitsToNat(parts[1]) else return null;
    let ?d = digitsToNat(parts[2]) else return null;
    if (m < 1 or m > 12 or d < 1) return null;
    if (d > Int.abs(daysInMonth(y, m))) return null;
    ?daysFromCivil(y, m, d);
  };

  // Accepts "YYYY-MM-DD", "today", "+30", "-7".
  func parseDayArg(t : Text) : ?Int {
    let s = Text.trim(t, #char ' ');
    if (lower(s) == "today") return ?today();
    if (Text.startsWith(s, #char '+')) {
      let ?n = digitsToNat(Text.trimStart(s, #char '+')) else return null;
      return ?(today() + n);
    };
    if (Text.startsWith(s, #char '-') and splitParts(s, '-').size() == 2) {
      let ?n = digitsToNat(Text.trimStart(s, #char '-')) else return null;
      return ?(today() - n);
    };
    parseDate(s);
  };

  // Principal.fromText traps on garbage and `try` is not available outside an
  // async context, so the shape is validated before parsing rather than after.
  func parsePrincipal(t : Text) : ?Principal {
    let trimmed = Text.trim(t, #char ' ');
    let n = trimmed.size();
    if (n < 5 or n > 63) return null;
    for (c in trimmed.chars()) {
      let ok = (Char.isLowercase(c) and Char.isAlphabetic(c)) or Char.isDigit(c) or c == '-';
      if (not ok) return null;
    };
    let p = Principal.fromText(trimmed);
    if (Principal.isAnonymous(p)) return null;
    ?p;
  };

  func hexToBlob(t : Text) : ?Blob {
    let s = if (Text.startsWith(t, #text "0x")) Text.trimStart(t, #text "0x") else t;
    if (s.size() % 2 != 0) return null;
    let out = Buffer.Buffer<Nat8>(32);
    var hi : ?Nat = null;
    for (c in s.chars()) {
      let v : Nat = if (Char.isDigit(c)) Nat32.toNat(Char.toNat32(c) - 48) else if (c >= 'a' and c <= 'f') Nat32.toNat(Char.toNat32(c) - 87) else if (c >= 'A' and c <= 'F') Nat32.toNat(Char.toNat32(c) - 55) else return null;
      switch (hi) {
        case (null) hi := ?v;
        case (?h) { out.add(Nat8.fromNat(h * 16 + v)); hi := null };
      };
    };
    ?Blob.fromArray(Buffer.toArray(out));
  };

  func parseKind(t : Text) : ?AccountKind {
    switch (lower(t)) {
      case ("asset") ?#asset;
      case ("liability") ?#liability;
      case ("equity") ?#equity;
      case ("income") ?#income;
      case ("revenue") ?#income;
      case ("expense") ?#expense;
      case (_) null;
    };
  };

  // --- ARG HELPERS ---

  func optText(args : McpTypes.JsonValue, field : Text) : ?Text {
    switch (Result.toOption(Json.getAsText(args, field))) {
      case (?t) { let v = Text.trim(t, #char ' '); if (v == "") null else ?v };
      case (null) null;
    };
  };

  func floatFromText(t : Text) : ?Float {
    var whole : Float = 0.0;
    var frac : Float = 0.0;
    var scale : Float = 1.0;
    var seenDot = false;
    var seenDigit = false;
    var negative = false;
    var first = true;
    for (c in t.chars()) {
      if (first and c == '-') { negative := true } else if (c == '.') {
        if (seenDot) return null;
        seenDot := true;
      } else if (Char.isDigit(c)) {
        seenDigit := true;
        let d = Float.fromInt(Nat32.toNat(Char.toNat32(c) - 48));
        if (seenDot) { scale *= 10.0; frac += d / scale } else { whole := whole * 10.0 + d };
      } else if (c == ',' or c == '$' or c == ' ') {
        // Agents pass "$1,200" more often than you'd like.
      } else return null;
      first := false;
    };
    if (not seenDigit) return null;
    let v = whole + frac;
    ?(if (negative) -v else v);
  };

  func optFloat(args : McpTypes.JsonValue, field : Text) : ?Float {
    switch (Result.toOption(Json.getAsFloat(args, field))) {
      case (?f) ?f;
      case (null) {
        switch (Result.toOption(Json.getAsText(args, field))) {
          case (?t) floatFromText(Text.trim(t, #char ' '));
          case (null) null;
        };
      };
    };
  };

  // Every amount in this server is MINOR UNITS as an integer. 4500 is $45.00.
  // A fractional cent is a rounding decision nobody asked this server to make,
  // so it is refused rather than rounded.
  func optMinor(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (optFloat(args, field)) {
      case (?f) {
        if (f < 0.0) return null;
        let r = Float.toInt(f + 0.5);
        if (Float.abs(f - Float.fromInt(r)) > 0.001) return null;
        ?Int.abs(r);
      };
      case (null) null;
    };
  };

  func optNat(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (optFloat(args, field)) {
      case (?f) { if (f < 0.0) null else ?Int.abs(Float.toInt(f + 0.5)) };
      case (null) null;
    };
  };

  func optBool(args : McpTypes.JsonValue, field : Text) : ?Bool {
    switch (Result.toOption(Json.getAsBool(args, field))) {
      case (?b) ?b;
      case (null) {
        switch (optText(args, field)) {
          case (?t) { let l = lower(t); if (l == "true" or l == "yes") ?true else if (l == "false" or l == "no") ?false else null };
          case (null) null;
        };
      };
    };
  };

  func errorResult(msg : Text) : McpTypes.CallToolResult {
    { content = [#text({ text = msg })]; isError = true; structuredContent = null };
  };

  func okResult(payload : Json.Json) : McpTypes.CallToolResult {
    {
      content = [#text({ text = Json.stringify(payload, null) })];
      isError = false;
      structuredContent = ?payload;
    };
  };

  func optJsonText(t : ?Text) : Json.Json {
    switch (t) { case (?v) Json.str(v); case (null) Json.nullable() };
  };

  func optJsonDate(d : ?Int) : Json.Json {
    switch (d) { case (?v) Json.str(fmtDate(v)); case (null) Json.nullable() };
  };

  // --- STORAGE HELPERS ---

  func entryKey(owner : Principal, seq : Nat) : Text {
    Principal.toText(owner) # "#" # Nat.toText(seq);
  };

  func grantKey(owner : Principal, reader : Principal) : Text {
    Principal.toText(owner) # "#" # Principal.toText(reader);
  };

  func ownerAccountIds(p : Principal) : [Nat] {
    switch (Map.get(accountIdsByOwner, phash, p)) { case (?ids) ids; case (null) [] };
  };

  func ownerAccounts(p : Principal) : [Account] {
    let out = Buffer.Buffer<Account>(16);
    for (id in ownerAccountIds(p).vals()) {
      switch (Map.get(accountsById, nhash, id)) { case (?a) out.add(a); case (null) {} };
    };
    Buffer.toArray(out);
  };

  // Accounts are addressed by code, not internal id, so an agent can post
  // without a lookup round-trip.
  func accountByCode(p : Principal, code : Text) : ?Account {
    for (a in ownerAccounts(p).vals()) { if (a.code == code) return ?a };
    null;
  };

  func accountById(id : Nat) : ?Account {
    Map.get(accountsById, nhash, id);
  };

  func putAccount(a : Account) { Map.set(accountsById, nhash, a.id, a) };

  func ownerSeqs(p : Principal) : [Nat] {
    switch (Map.get(entrySeqsByOwner, phash, p)) { case (?s) s; case (null) [] };
  };

  func getEntry(owner : Principal, seq : Nat) : ?Entry {
    Map.get(entriesByKey, thash, entryKey(owner, seq));
  };

  func putEntry(e : Entry) { Map.set(entriesByKey, thash, entryKey(e.owner, e.seq), e) };

  func ownerEntries(p : Principal) : [Entry] {
    let out = Buffer.Buffer<Entry>(32);
    for (s in ownerSeqs(p).vals()) {
      switch (getEntry(p, s)) { case (?e) out.add(e); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func entryCount(p : Principal) : Nat { ownerSeqs(p).size() };

  func takeSeq(p : Principal) : Nat {
    let n = switch (Map.get(nextSeqByOwner, phash, p)) { case (?v) v; case (null) 1 };
    Map.set(nextSeqByOwner, phash, p, n + 1);
    n;
  };

  func recordSeq(p : Principal, seq : Nat) {
    Map.set(entrySeqsByOwner, phash, p, Array.append(ownerSeqs(p), [seq]));
  };

  func ownerGrantKeys(p : Principal) : [Text] {
    switch (Map.get(grantKeysByOwner, phash, p)) { case (?k) k; case (null) [] };
  };

  func liveGrant(owner : Principal, reader : Principal, todayDay : Int) : ?ReaderGrant {
    switch (Map.get(grantsByKey, thash, grantKey(owner, reader))) {
      case (?g) { if (g.expiresDay >= todayDay) ?g else null };
      case (null) null;
    };
  };

  // --- BALANCES ---
  //
  // Balances are computed from the entries every time rather than cached on the
  // account. A cached balance is a second source of truth that can silently
  // disagree with the first, and the entries are the books.

  func inRange(day : Int, from : ?Int, to : ?Int) : Bool {
    switch (from) { case (?f) { if (day < f) return false }; case (null) {} };
    switch (to) { case (?t) { if (day > t) return false }; case (null) {} };
    true;
  };

  // accountId -> (debits - credits), one pass over the owner's entries.
  func balancesFor(owner : Principal, from : ?Int, to : ?Int) : Map.Map<Nat, Int> {
    let acc : Map.Map<Nat, Int> = Map.new();
    for (e in ownerEntries(owner).vals()) {
      if (inRange(e.day, from, to)) {
        for (l in e.lines.vals()) {
          let prev = switch (Map.get(acc, nhash, l.account)) { case (?v) v; case (null) 0 };
          let delta : Int = switch (l.side) { case (#debit) l.minor; case (#credit) -l.minor };
          Map.set(acc, nhash, l.account, prev + delta);
        };
      };
    };
    acc;
  };

  func balanceOf(acc : Map.Map<Nat, Int>, id : Nat) : Int {
    switch (Map.get(acc, nhash, id)) { case (?v) v; case (null) 0 };
  };

  // Total debits and total credits over a range — the trial balance's proof.
  func totalsFor(owner : Principal, from : ?Int, to : ?Int) : (Nat, Nat) {
    var d : Nat = 0;
    var c : Nat = 0;
    for (e in ownerEntries(owner).vals()) {
      if (inRange(e.day, from, to)) {
        for (l in e.lines.vals()) {
          switch (l.side) { case (#debit) d += l.minor; case (#credit) c += l.minor };
        };
      };
    };
    (d, c);
  };

  // Net income over a range: income (credit-normal) minus expenses.
  func netIncome(owner : Principal, from : ?Int, to : ?Int) : Int {
    let acc = balancesFor(owner, from, to);
    var income : Int = 0;
    var expense : Int = 0;
    for (a in ownerAccounts(owner).vals()) {
      let dmc = balanceOf(acc, a.id);
      switch (a.kind) {
        case (#income) income += normalized(#income, dmc);
        case (#expense) expense += normalized(#expense, dmc);
        case (_) {};
      };
    };
    income - expense;
  };

  func sortedAccounts(owner : Principal, includeArchived : Bool) : [Account] {
    let all = ownerAccounts(owner);
    let kept = Array.filter<Account>(all, func(a) { includeArchived or not a.archived });
    Array.sort<Account>(kept, func(x, y) { Text.compare(x.code, y.code) });
  };

  // --- AUTHORIZATION ---
  //
  // Writes are owner-only, always. Reads are owner-or-live-reader, which is what
  // makes "send this to my accountant" work without handing over the keys.

  type ToolCb = (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ();

  func callerPrincipal(auth : ?AuthTypes.AuthInfo) : ?Principal {
    switch (auth) { case (?a) ?a.principal; case (null) null };
  };

  func requireAuth(auth : ?AuthTypes.AuthInfo, cb : ToolCb) : ?Principal {
    switch (callerPrincipal(auth)) {
      case (?p) ?p;
      case (null) {
        cb(#ok(errorResult("Authentication required: call this tool with a valid x-api-key.")));
        null;
      };
    };
  };

  // Is this principal a live reader on anyone's books? Used only to explain a
  // write refusal properly — someone holding a read grant who tries to post
  // should be told that reads and writes are different, not told to set up books.
  func readsSomeonesBooks(p : Principal, todayDay : Int) : Bool {
    for (g in Map.vals(grantsByKey)) {
      if (g.reader == p and g.expiresDay >= todayDay) return true;
    };
    false;
  };

  // Books the caller may WRITE to: their own, and they must exist.
  func requireOwnBooks(p : Principal, cb : ToolCb) : ?Books {
    switch (Map.get(books, phash, p)) {
      case (?b) ?b;
      case (null) {
        let extra = if (readsSomeonesBooks(p, today())) " You do hold read access to someone else's books, but this tool writes, and a reader grant never permits posting, reversing, closing, or granting." else "";
        cb(#ok(errorResult("No books yet for this principal. Call setup_books first — it seeds a standard chart of accounts you can edit afterwards." # extra)));
        null;
      };
    };
  };

  // Books the caller may READ: their own, or someone else's if that owner has
  // granted them an unexpired reader grant. Returns (owner, books).
  func requireReadableBooks(args : McpTypes.JsonValue, p : Principal, cb : ToolCb) : ?(Principal, Books) {
    let owner = switch (optText(args, "books")) {
      case (?t) {
        let ?parsed = parsePrincipal(t) else {
          cb(#ok(errorResult("'books' is not a valid principal.")));
          return null;
        };
        parsed;
      };
      case (null) p;
    };
    let ?b = Map.get(books, phash, owner) else {
      cb(#ok(errorResult(if (owner == p) "No books yet for this principal. Call setup_books first." else "No books exist for " # Principal.toText(owner) # ".")));
      return null;
    };
    if (owner == p) return ?(owner, b);
    switch (liveGrant(owner, p, today())) {
      case (?_) ?(owner, b);
      case (null) {
        cb(#ok(errorResult("Not authorized to read those books. The owner can grant you scoped, expiring read access with grant_reader — a grant is read-only and never permits posting.")));
        null;
      };
    };
  };

  func requireAccount(owner : Principal, code : Text, cb : ToolCb) : ?Account {
    switch (accountByCode(owner, code)) {
      case (?a) ?a;
      case (null) {
        cb(#ok(errorResult("No account with code '" # code # "'. Call list_accounts to see the chart of accounts.")));
        null;
      };
    };
  };

  // --- JSON VIEWS ---

  func linkedToJson(l : LinkedLedger) : Json.Json {
    Json.obj([
      ("ledger", Json.str(l.ledger)),
      ("account", Json.str(Principal.toText(l.account))),
      ("subaccount", switch (l.subaccount) { case (?_) Json.str("set"); case (null) Json.nullable() }),
      ("last_chain_minor", switch (l.lastChainMinor) { case (?v) Json.int(v); case (null) Json.nullable() }),
      ("last_reconciled_at_ns", switch (l.lastReconciledAt) { case (?v) Json.int(v); case (null) Json.nullable() }),
    ]);
  };

  func accountToJson(a : Account, bal : Int, cur : Text) : Json.Json {
    Json.obj([
      ("code", Json.str(a.code)),
      ("name", Json.str(a.name)),
      ("kind", Json.str(kindText(a.kind))),
      ("balance_minor", Json.int(bal)),
      ("balance", Json.str(fmtMinor(bal, cur))),
      ("normal_side", Json.str(if (isDebitNormal(a.kind)) "debit" else "credit")),
      ("archived", Json.bool(a.archived)),
      ("linked", switch (a.linked) { case (?l) linkedToJson(l); case (null) Json.nullable() }),
    ]);
  };

  func lineToJson(l : Line, cur : Text) : Json.Json {
    let code = switch (accountById(l.account)) { case (?a) a.code; case (null) "?" };
    let name = switch (accountById(l.account)) { case (?a) a.name; case (null) "(deleted account)" };
    Json.obj([
      ("account", Json.str(code)),
      ("account_name", Json.str(name)),
      ("side", Json.str(sideText(l.side))),
      ("minor", Json.int(l.minor)),
      ("amount", Json.str(fmtMinor(l.minor, cur))),
      ("memo", optJsonText(l.memo)),
    ]);
  };

  func rateToJson(r : Rate) : Json.Json {
    Json.obj([
      ("symbol", Json.str(r.symbol)),
      ("units", Json.int(r.units)),
      ("minor_per_unit", Json.int(r.minorPerUnit)),
      ("source", Json.str(r.source)),
      ("observed_at_ns", Json.int(r.at)),
    ]);
  };

  func refToJson(r : Ref) : Json.Json {
    Json.obj([
      ("source", Json.str(r.source)),
      ("id", Json.str(r.id)),
      ("canister", optJsonText(r.canister)),
    ]);
  };

  func entryToJson(e : Entry, cur : Text) : Json.Json {
    var debits : Nat = 0;
    for (l in e.lines.vals()) { switch (l.side) { case (#debit) debits += l.minor; case (#credit) {} } };
    Json.obj([
      ("seq", Json.int(e.seq)),
      ("date", Json.str(fmtDate(e.day))),
      ("memo", Json.str(e.memo)),
      ("total_minor", Json.int(debits)),
      ("total", Json.str(fmtMinor(debits, cur))),
      ("lines", Json.arr(Array.map<Line, Json.Json>(e.lines, func(l) { lineToJson(l, cur) }))),
      ("rate", switch (e.rate) { case (?r) rateToJson(r); case (null) Json.nullable() }),
      ("ref", switch (e.ref) { case (?r) refToJson(r); case (null) Json.nullable() }),
      ("reverses", switch (e.reverses) { case (?s) Json.int(s); case (null) Json.nullable() }),
      ("reversed_by", switch (e.reversedBy) { case (?s) Json.int(s); case (null) Json.nullable() }),
      ("posted_at_ns", Json.int(e.postedAt)),
    ]);
  };

  func booksToJson(b : Books, p : Principal) : Json.Json {
    Json.obj([
      ("owner", Json.str(Principal.toText(b.owner))),
      ("base_currency", Json.str(b.baseCurrency)),
      ("fiscal_year_start_month", Json.int(b.fiscalYearStartMonth)),
      ("basis", Json.str(basisText(b.basis))),
      ("closed_through", optJsonDate(b.closedThrough)),
      ("entries", Json.int(entryCount(p))),
      ("accounts", Json.int(ownerAccountIds(p).size())),
    ]);
  };

  // --- TOOL SCHEMAS ---

  func schemaProp(name : Text, jsonType : Text, description : Text) : (Text, Json.Json) {
    (name, Json.obj([("type", Json.str(jsonType)), ("description", Json.str(description))]));
  };

  func arrayProp(name : Text, description : Text) : (Text, Json.Json) {
    (
      name,
      Json.obj([
        ("type", Json.str("array")),
        ("description", Json.str(description)),
        ("items", Json.obj([("type", Json.str("object"))])),
      ]),
    );
  };

  func objProp(name : Text, description : Text) : (Text, Json.Json) {
    (name, Json.obj([("type", Json.str("object")), ("description", Json.str(description))]));
  };

  func objSchema(props : [(Text, Json.Json)], required : [Text]) : Json.Json {
    Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj(props)),
      ("required", Json.arr(Array.map<Text, Json.Json>(required, Json.str))),
    ]);
  };

  transient let booksArg = schemaProp("books", "string", "Read someone else's books by owner principal, if they granted you access. Defaults to your own.");

  transient let messageSchema : Json.Json = objSchema([schemaProp("message", "string", "Confirmation message.")], ["message"]);

  transient let tools : [McpTypes.Tool] = [
    {
      name = "setup_books";
      title = ?"Set Up Books";
      description = ?"Create your books and seed a standard chart of accounts you can edit afterwards. Choose cash or accrual basis here: cash recognizes income when payment clears, accrual when the invoice is sent. Basis and base currency are locked once the first entry is posted, because switching afterwards would require restating every open receivable.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("base_currency", "string", "Currency code the books are kept in. Default USD."),
          schemaProp("fiscal_year_start_month", "integer", "Month your fiscal year starts, 1-12. Default 1 (January)."),
          schemaProp("basis", "string", "'cash' (default) or 'accrual'."),
        ],
        [],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "update_books";
      title = ?"Update Books Settings";
      description = ?"Change fiscal year start, base currency, or basis. Currency and basis are refused once any entry exists — the error tells you how many entries are in the way.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("base_currency", "string", "New base currency code."),
          schemaProp("fiscal_year_start_month", "integer", "New fiscal year start month, 1-12."),
          schemaProp("basis", "string", "'cash' or 'accrual'."),
        ],
        [],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "add_account";
      title = ?"Add Account";
      description = ?"Add an account to the chart of accounts: a numeric code, a name, and a kind (asset, liability, equity, income, expense). Codes sort the chart and are how every other tool addresses an account.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("code", "string", "Account code, e.g. '6300'. Must be unique in your chart."),
          schemaProp("name", "string", "Account name, e.g. 'Contractor Labor'."),
          schemaProp("kind", "string", "asset, liability, equity, income, or expense."),
          schemaProp("parent", "string", "Optional parent account code, for sub-accounts."),
        ],
        ["code", "name", "kind"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "list_accounts";
      title = ?"List Accounts";
      description = ?"The chart of accounts with each account's current balance, in code order. Balances are shown in each account's normal direction, so revenue and liabilities read positive rather than negative.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("include_archived", "boolean", "Include retired accounts. Default false."),
          schemaProp("kind", "string", "Filter to one kind: asset, liability, equity, income, expense."),
          booksArg,
        ],
        [],
      );
      outputSchema = ?objSchema([schemaProp("count", "integer", "Accounts returned.")], []);
    },
    {
      name = "archive_account";
      title = ?"Archive Account";
      description = ?"Retire an account so it stops appearing in the chart. Refused if it still holds a balance, and the balance is in the error. Accounts are never deleted — historical entries point at them.";
      payment = null;
      inputSchema = objSchema([schemaProp("code", "string", "Account code to archive.")], ["code"]);
      outputSchema = ?messageSchema;
    },
    {
      name = "link_account";
      title = ?"Link Account To Ledger";
      description = ?"Bind an asset account to a real ICRC ledger account so reconcile can check the books against the chain. Read-only: this never grants the canister any ability to move funds.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("code", "string", "Asset account code to link, e.g. '1000'."),
          schemaProp("ledger", "string", "ICRC ledger canister id. Defaults to the ckUSDC ledger."),
          schemaProp("account", "string", "Principal whose balance this account mirrors. Defaults to your calling principal."),
          schemaProp("subaccount", "string", "Optional subaccount as hex."),
        ],
        ["code"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "post_entry";
      title = ?"Post Entry";
      description = ?"The core tool. Post a balanced double-entry transaction: a date, a memo, and two or more lines each carrying exactly one of debit or credit. Amounts are base-currency MINOR UNITS as integers — 4500 means $45.00. Refused unless debits equal credits and the period is open.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("day", "string", "Accounting date: 'YYYY-MM-DD', 'today', or '+3'. Defaults to today."),
          schemaProp("memo", "string", "What this transaction was."),
          arrayProp("lines", "2-64 lines. Each is {account: '1000', debit: 4500} or {account: '4000', credit: 4500}, with an optional per-line memo. Amounts in minor units."),
          objProp("rate", "Required if the movement was token-denominated: {symbol, units, minor_per_unit, source}. Frozen at post time and never looked up again."),
          objProp("ref", "Where this came from: {source, id, canister}. e.g. {source: 'invoice-desk', id: 'inv-17'}."),
        ],
        ["memo", "lines"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "record_invoice";
      title = ?"Record Invoice";
      description = ?"Record an invoice you sent. On accrual basis this debits Accounts Receivable and credits income. On cash basis nothing is posted yet — income is recognized when the payment clears — and the response says so rather than silently doing nothing.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("amount", "integer", "Invoice total in minor units, e.g. 45000 for $450.00."),
          schemaProp("invoice_id", "string", "Your invoice reference, e.g. 'inv-17'."),
          schemaProp("day", "string", "Invoice date. Defaults to today."),
          schemaProp("customer", "string", "Optional customer name, recorded in the memo."),
          schemaProp("income_account", "string", "Income account code. Default 4000 Service Revenue."),
          schemaProp("receivable_account", "string", "Receivable account code. Default 1100."),
          schemaProp("canister", "string", "Optional source canister id, e.g. the Invoice Desk canister."),
        ],
        ["amount", "invoice_id"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "record_payment";
      title = ?"Record Payment";
      description = ?"Record money received against an invoice. On accrual basis this clears the receivable; on cash basis it recognizes the income now. Either way the cash account is debited.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("amount", "integer", "Amount received in minor units."),
          schemaProp("invoice_id", "string", "The invoice this pays, e.g. 'inv-17'."),
          schemaProp("day", "string", "Payment date. Defaults to today."),
          schemaProp("cash_account", "string", "Cash account code that received it. Default 1000."),
          schemaProp("income_account", "string", "Cash basis only: income account to credit. Default 4000."),
          schemaProp("receivable_account", "string", "Accrual basis only: receivable to clear. Default 1100."),
          schemaProp("canister", "string", "Optional source canister id."),
        ],
        ["amount", "invoice_id"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "record_expense";
      title = ?"Record Expense";
      description = ?"The common case: money out, one category, one source of funds. Debits the category account and credits the account it was paid from. If you cannot classify it, leave the category off and it posts to 6900 Uncategorized, where the review sweep will find it — this server never guesses a category.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("amount", "integer", "Amount in minor units."),
          schemaProp("memo", "string", "What it was for."),
          schemaProp("day", "string", "Date. Defaults to today."),
          schemaProp("category", "string", "Expense account code. Defaults to 6900 Uncategorized."),
          schemaProp("paid_from", "string", "Account the money left. Default 1000."),
          schemaProp("vendor", "string", "Optional vendor name."),
          schemaProp("source", "string", "Optional ref source, e.g. 'subscription-auditor'."),
          schemaProp("ref_id", "string", "Optional ref id, e.g. a subscription id."),
        ],
        ["amount", "memo"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "get_entry";
      title = ?"Get Entry";
      description = ?"One entry in full, with its lines, its source reference, and its reversal links in both directions.";
      payment = null;
      inputSchema = objSchema([schemaProp("seq", "integer", "The entry sequence number."), booksArg], ["seq"]);
      outputSchema = ?objSchema([objProp("entry", "The entry.")], []);
    },
    {
      name = "list_entries";
      title = ?"List Entries";
      description = ?"Entries newest first, filtered by account, date range, or source. This is the journal.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("account", "string", "Filter to entries touching this account code."),
          schemaProp("from", "string", "Start date, inclusive."),
          schemaProp("to", "string", "End date, inclusive."),
          schemaProp("source", "string", "Filter by ref source, e.g. 'invoice-desk'."),
          schemaProp("limit", "integer", "Max rows, default 50."),
          booksArg,
        ],
        [],
      );
      outputSchema = ?objSchema([schemaProp("count", "integer", "Entries returned.")], []);
    },
    {
      name = "reverse_entry";
      title = ?"Reverse Entry";
      description = ?"Correct a mistake by posting a mirrored entry that cancels an earlier one, linking both directions. Requires a reason. This is the only way to undo a posting — entries are never edited or deleted, because deletable books are worthless books.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("seq", "integer", "The entry to reverse."),
          schemaProp("reason", "string", "Why it is being reversed. Recorded in the reversing entry's memo."),
        ],
        ["seq", "reason"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "profit_and_loss";
      title = ?"Profit And Loss";
      description = ?"Income and expenses for a period with a prior-period comparison of the same length. Defaults to the fiscal year to date.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("from", "string", "Start date. Defaults to the start of the current fiscal year."),
          schemaProp("to", "string", "End date. Defaults to today."),
          booksArg,
        ],
        [],
      );
      outputSchema = ?objSchema([schemaProp("net_income_minor", "integer", "Net income in minor units.")], []);
    },
    {
      name = "balance_sheet";
      title = ?"Balance Sheet";
      description = ?"Assets, liabilities and equity as of a date, including computed retained earnings, and an explicit assertion that assets equal liabilities plus equity. If that assertion ever fails the response says so loudly rather than hiding it.";
      payment = null;
      inputSchema = objSchema([schemaProp("as_of", "string", "Date. Defaults to today."), booksArg], []);
      outputSchema = ?objSchema([schemaProp("balances", "boolean", "Whether the accounting equation holds.")], []);
    },
    {
      name = "trial_balance";
      title = ?"Trial Balance";
      description = ?"Every account's debit and credit totals, and the proof that they are equal. This is the check an accountant runs first.";
      payment = null;
      inputSchema = objSchema([schemaProp("as_of", "string", "Date. Defaults to today."), booksArg], []);
      outputSchema = ?objSchema([schemaProp("balanced", "boolean", "Whether total debits equal total credits.")], []);
    },
    {
      name = "account_ledger";
      title = ?"Account Ledger";
      description = ?"One account's entries in date order with a running balance — the detail behind a number on a report.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("account", "string", "Account code."),
          schemaProp("from", "string", "Start date."),
          schemaProp("to", "string", "End date."),
          schemaProp("limit", "integer", "Max rows, default 100."),
          booksArg,
        ],
        ["account"],
      );
      outputSchema = ?objSchema([schemaProp("closing_balance_minor", "integer", "Closing balance in minor units.")], []);
    },
    {
      name = "reconcile";
      title = ?"Reconcile Account";
      description = ?"Compare a linked asset account's book balance against its live on-chain balance, and return the signed difference alongside the entries posted since the last reconciliation — so the answer to 'where did the $340 go' is in the same response as the $340. Chain amounts are converted from the ledger's own decimals into your books' cents, and the conversion is stated.";
      payment = null;
      inputSchema = objSchema([schemaProp("account", "string", "Linked asset account code, e.g. '1000'.")], ["account"]);
      outputSchema = ?objSchema([schemaProp("difference_minor", "integer", "Book minus chain, in minor units.")], []);
    },
    {
      name = "tax_summary";
      title = ?"Tax Summary";
      description = ?"Categorized income and deductible expense totals for a fiscal year, with a quarterly estimate. This is NOT tax advice and does not file anything: it returns totals plus an explicit list of the rules it applied, so a human or their accountant can decide what they mean.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("year", "integer", "Fiscal year to summarize, by its starting calendar year. Defaults to the current one."),
          schemaProp("estimated_rate_pct", "number", "Your assumed combined tax rate as a percent, used only for the quarterly estimate. Default 25."),
          booksArg,
        ],
        [],
      );
      outputSchema = ?objSchema([schemaProp("net_income_minor", "integer", "Net income for the year.")], []);
    },
    {
      name = "review";
      title = ?"Review Books";
      description = ?"The sweep: anything sitting in Uncategorized, linked accounts that have never been reconciled or have gone stale, receivables past due, whether the trial balance still balances, and whether a period is ready to close. Run this before you close anything.";
      payment = null;
      inputSchema = objSchema([booksArg], []);
      outputSchema = ?objSchema([schemaProp("issues", "integer", "Number of findings.")], []);
    },
    {
      name = "close_period";
      title = ?"Close Period";
      description = ?"Lock everything on or before a date so nothing can be back-dated into filed books. Refused while the trial balance does not balance or anything is still in Uncategorized, listing what blocks it. Requires confirm:true, because reopening a period is deliberately not a tool — 'unfiled my taxes' is not something an agent should be able to do on its own.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("through", "string", "Close everything on or before this date."),
          schemaProp("confirm", "boolean", "Must be true. Closing cannot be undone here."),
        ],
        ["through", "confirm"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "grant_reader";
      title = ?"Grant Reader Access";
      description = ?"Give another principal read-only access to your books until a date you choose — how you hand the books to an accountant without handing over the keys. A grant never permits posting, editing, closing, or granting, and it always expires.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("principal", "string", "The principal to grant read access to."),
          schemaProp("expires", "string", "Expiry date: 'YYYY-MM-DD' or '+90'. Required — a permission with no end date is one nobody revokes."),
          schemaProp("note", "string", "Optional note, e.g. 'accountant, FY2026 filing'."),
        ],
        ["principal", "expires"],
      );
      outputSchema = ?messageSchema;
    },
    {
      name = "revoke_reader";
      title = ?"Revoke Reader Access";
      description = ?"Immediately end a principal's read access to your books.";
      payment = null;
      inputSchema = objSchema([schemaProp("principal", "string", "The principal to revoke.")], ["principal"]);
      outputSchema = ?messageSchema;
    },
    {
      name = "list_readers";
      title = ?"List Readers";
      description = ?"Who can read your books, when their access expires, and whether it is still live.";
      payment = null;
      inputSchema = objSchema([], []);
      outputSchema = ?objSchema([schemaProp("count", "integer", "Grants returned.")], []);
    },
  ];

  // --- TOOL IMPLEMENTATIONS: SETUP ---

  func setupBooksTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    switch (Map.get(books, phash, p)) {
      case (?_) return cb(#ok(errorResult("Books already exist for this principal. Use update_books to change settings — setup_books is refused rather than overwriting books that may already hold entries.")));
      case (null) {};
    };

    let cur = switch (optText(args, "base_currency")) { case (?c) c; case (null) "USD" };
    let fym = switch (optNat(args, "fiscal_year_start_month")) {
      case (?m) { if (m < 1 or m > 12) return cb(#ok(errorResult("'fiscal_year_start_month' must be 1-12."))) else m };
      case (null) 1;
    };
    let basis = switch (optText(args, "basis")) {
      case (?t) {
        switch (lower(t)) {
          case ("cash") #cash;
          case ("accrual") #accrual;
          case (_) return cb(#ok(errorResult("'basis' must be 'cash' or 'accrual'.")));
        };
      };
      case (null) #cash;
    };

    let now = Time.now();
    Map.set(books, phash, p, { owner = p; baseCurrency = cur; fiscalYearStartMonth = fym; basis = basis; closedThrough = null; createdAt = now });

    let ids = Buffer.Buffer<Nat>(defaultChart.size());
    for ((code, name, kind) in defaultChart.vals()) {
      let id = nextAccountId;
      nextAccountId += 1;
      putAccount({ id = id; owner = p; code = code; name = name; kind = kind; parent = null; linked = null; archived = false; createdAt = now });
      ids.add(id);
    };
    Map.set(accountIdsByOwner, phash, p, Buffer.toArray(ids));

    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Books created on a " # basisText(basis) # " basis in " # cur # ", with " # Nat.toText(defaultChart.size()) # " accounts seeded. Basis and currency lock once the first entry is posted.")),
      ("books", booksToJson({ owner = p; baseCurrency = cur; fiscalYearStartMonth = fym; basis = basis; closedThrough = null; createdAt = now }, p)),
    ]))));
  };

  func updateBooksTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let n = entryCount(p);

    var cur = b.baseCurrency;
    switch (optText(args, "base_currency")) {
      case (?c) {
        if (c != b.baseCurrency and n > 0) return cb(#ok(errorResult("Base currency is locked: " # Nat.toText(n) # " entries are already denominated in " # b.baseCurrency # ". Changing it would silently restate every one of them.")));
        cur := c;
      };
      case (null) {};
    };

    var basis = b.basis;
    switch (optText(args, "basis")) {
      case (?t) {
        let nb = switch (lower(t)) {
          case ("cash") #cash;
          case ("accrual") #accrual;
          case (_) return cb(#ok(errorResult("'basis' must be 'cash' or 'accrual'.")));
        };
        if (nb != b.basis and n > 0) return cb(#ok(errorResult("Basis is locked: " # Nat.toText(n) # " entries already exist. Switching between cash and accrual requires restating every open receivable, which this server deliberately does not do.")));
        basis := nb;
      };
      case (null) {};
    };

    var fym = b.fiscalYearStartMonth;
    switch (optNat(args, "fiscal_year_start_month")) {
      case (?m) { if (m < 1 or m > 12) return cb(#ok(errorResult("'fiscal_year_start_month' must be 1-12."))); fym := m };
      case (null) {};
    };

    let nb : Books = { b with baseCurrency = cur; basis = basis; fiscalYearStartMonth = fym };
    Map.set(books, phash, p, nb);
    cb(#ok(okResult(Json.obj([("message", Json.str("Books updated.")), ("books", booksToJson(nb, p))]))));
  };

  func addAccountTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?_ = requireOwnBooks(p, cb) else return;
    let ?code = optText(args, "code") else return cb(#ok(errorResult("Missing 'code'.")));
    let ?name = optText(args, "name") else return cb(#ok(errorResult("Missing 'name'.")));
    let ?kindT = optText(args, "kind") else return cb(#ok(errorResult("Missing 'kind'. Use asset, liability, equity, income, or expense.")));
    let ?kind = parseKind(kindT) else return cb(#ok(errorResult("'" # kindT # "' is not an account kind. Use asset, liability, equity, income, or expense.")));

    switch (accountByCode(p, code)) {
      case (?a) return cb(#ok(errorResult("Account code '" # code # "' is already '" # a.name # "'. Codes must be unique.")));
      case (null) {};
    };

    let parent = switch (optText(args, "parent")) {
      case (?pc) {
        let ?pa = requireAccount(p, pc, cb) else return;
        ?pa.id;
      };
      case (null) null;
    };

    let id = nextAccountId;
    nextAccountId += 1;
    let a : Account = { id = id; owner = p; code = code; name = name; kind = kind; parent = parent; linked = null; archived = false; createdAt = Time.now() };
    putAccount(a);
    Map.set(accountIdsByOwner, phash, p, Array.append(ownerAccountIds(p), [id]));
    cb(#ok(okResult(Json.obj([("message", Json.str("Added " # code # " " # name # " (" # kindText(kind) # ").")), ("account", accountToJson(a, 0, "USD"))]))));
  };

  func listAccountsTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;

    let includeArchived = switch (optBool(args, "include_archived")) { case (?v) v; case (null) false };
    let kindFilter = switch (optText(args, "kind")) { case (?t) parseKind(t); case (null) null };
    let acc = balancesFor(owner, null, null);

    let rows = Buffer.Buffer<Json.Json>(16);
    for (a in sortedAccounts(owner, includeArchived).vals()) {
      let keep = switch (kindFilter) { case (?k) a.kind == k; case (null) true };
      if (keep) rows.add(accountToJson(a, normalized(a.kind, balanceOf(acc, a.id)), b.baseCurrency));
    };

    cb(#ok(okResult(Json.obj([
      ("count", Json.int(rows.size())),
      ("base_currency", Json.str(b.baseCurrency)),
      ("accounts", Json.arr(Buffer.toArray(rows))),
      ("note", Json.str("Balances are shown in each account's normal direction: debit-normal for assets and expenses, credit-normal for liabilities, equity and income.")),
    ]))));
  };

  func archiveAccountTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?code = optText(args, "code") else return cb(#ok(errorResult("Missing 'code'.")));
    let ?a = requireAccount(p, code, cb) else return;
    if (a.archived) return cb(#ok(errorResult("Account " # code # " is already archived.")));

    let bal = normalized(a.kind, balanceOf(balancesFor(p, null, null), a.id));
    if (bal != 0) return cb(#ok(errorResult("Cannot archive " # code # " " # a.name # ": it still holds " # fmtMinor(bal, b.baseCurrency) # ". Move the balance out with a posting first.")));

    putAccount({ a with archived = true });
    cb(#ok(okResult(Json.obj([("message", Json.str("Archived " # code # " " # a.name # ". Historical entries still point at it."))]))));
  };

  func linkAccountTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?_ = requireOwnBooks(p, cb) else return;
    let ?code = optText(args, "code") else return cb(#ok(errorResult("Missing 'code'.")));
    let ?a = requireAccount(p, code, cb) else return;
    if (a.kind != #asset) return cb(#ok(errorResult("Only asset accounts can be linked to a ledger. " # code # " is " # aKind(a.kind) # " account.")));

    let ledgerId = switch (optText(args, "ledger")) {
      case (?l) { let ?_ = parsePrincipal(l) else return cb(#ok(errorResult("'ledger' is not a valid canister id."))); l };
      case (null) defaultLedger;
    };
    let acctPrincipal = switch (optText(args, "account")) {
      case (?t) { let ?parsed = parsePrincipal(t) else return cb(#ok(errorResult("'account' is not a valid principal."))); parsed };
      case (null) p;
    };
    let sub = switch (optText(args, "subaccount")) {
      case (?h) { let ?blob = hexToBlob(h) else return cb(#ok(errorResult("'subaccount' is not valid hex."))); ?blob };
      case (null) null;
    };

    putAccount({ a with linked = ?{ ledger = ledgerId; account = acctPrincipal; subaccount = sub; lastChainMinor = null; lastReconciledAt = null } });
    cb(#ok(okResult(Json.obj([("message", Json.str("Linked " # code # " " # a.name # " to ledger " # ledgerId # ". Run reconcile to compare it against the chain. This is a read-only binding — it grants no ability to move funds."))]))));
  };

  // --- TOOL IMPLEMENTATIONS: POSTING ---

  // Shared posting path. Every entry in this server goes through here, so the
  // balance check and the closed-period check cannot be bypassed by a
  // convenience tool.
  func postValidated(
    p : Principal,
    b : Books,
    day : Int,
    memo : Text,
    lines : [Line],
    rate : ?Rate,
    ref : ?Ref,
    reverses : ?Nat,
  ) : Result.Result<Entry, Text> {
    if (lines.size() < 2) return #err("An entry needs at least two lines — that is what makes it double-entry.");
    if (lines.size() > 64) return #err("An entry is capped at 64 lines.");

    switch (b.closedThrough) {
      case (?c) { if (day <= c) return #err("Period is closed through " # fmtDate(c) # "; nothing can post on or before that date. Back-dating into filed books is exactly what closing prevents.") };
      case (null) {};
    };

    var debits : Nat = 0;
    var credits : Nat = 0;
    for (l in lines.vals()) {
      if (l.minor == 0) return #err("A line with a zero amount is not a posting. Remove it.");
      switch (l.side) { case (#debit) debits += l.minor; case (#credit) credits += l.minor };
    };
    if (debits != credits) {
      return #err("Entry does not balance: debits " # fmtMinor(debits, b.baseCurrency) # " vs credits " # fmtMinor(credits, b.baseCurrency) # ". Difference " # fmtMinor(debits - credits : Int, b.baseCurrency) # ".");
    };

    let seq = takeSeq(p);
    let e : Entry = {
      seq = seq;
      owner = p;
      day = day;
      memo = memo;
      lines = lines;
      rate = rate;
      ref = ref;
      reverses = reverses;
      reversedBy = null;
      postedAt = Time.now();
    };
    putEntry(e);
    recordSeq(p, seq);
    #ok(e);
  };

  func dayArgOr(args : McpTypes.JsonValue, field : Text, fallback : Int) : Result.Result<Int, Text> {
    switch (optText(args, field)) {
      case (?t) { switch (parseDayArg(t)) { case (?d) #ok(d); case (null) #err("'" # t # "' is not a date. Use 'YYYY-MM-DD', 'today', or '+3'.") } };
      case (null) #ok(fallback);
    };
  };

  func parseRate(args : McpTypes.JsonValue) : Result.Result<?Rate, Text> {
    let ?node = Json.get(args, "rate") else return #ok(null);
    let ?symbol = optText(node, "symbol") else return #err("'rate' needs a 'symbol', e.g. 'ICP'.");
    let ?units = optNat(node, "units") else return #err("'rate' needs 'units' — how much token moved, in the token's own minor units.");
    let ?mpu = optNat(node, "minor_per_unit") else return #err("'rate' needs 'minor_per_unit' — base-currency minor units per whole token.");
    let source = switch (optText(node, "source")) { case (?s) s; case (null) "manual" };
    #ok(?{ symbol = symbol; units = units; minorPerUnit = mpu; source = source; at = Time.now() });
  };

  func parseRef(args : McpTypes.JsonValue) : ?Ref {
    let ?node = Json.get(args, "ref") else return null;
    let ?source = optText(node, "source") else return null;
    let id = switch (optText(node, "id")) { case (?i) i; case (null) "" };
    ?{ source = source; id = id; canister = optText(node, "canister") };
  };

  func postEntryTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?memo = optText(args, "memo") else return cb(#ok(errorResult("Missing 'memo'. An entry nobody can read later is not a record.")));

    let day = switch (dayArgOr(args, "day", today())) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };
    let rate = switch (parseRate(args)) { case (#ok(r)) r; case (#err(m)) return cb(#ok(errorResult(m))) };

    let ?rawLines = Result.toOption(Json.getAsArray(args, "lines")) else return cb(#ok(errorResult("Missing 'lines'. Give an array like [{account:'1100', debit:45000},{account:'4000', credit:45000}] with amounts in minor units.")));

    let parsed = Buffer.Buffer<Line>(rawLines.size());
    var idx = 0;
    for (raw in rawLines.vals()) {
      idx += 1;
      let ?code = optText(raw, "account") else return cb(#ok(errorResult("Line " # Nat.toText(idx) # " is missing 'account'.")));
      let ?a = accountByCode(p, code) else return cb(#ok(errorResult("Line " # Nat.toText(idx) # ": no account with code '" # code # "'. Call list_accounts to see the chart.")));
      if (a.archived) return cb(#ok(errorResult("Line " # Nat.toText(idx) # ": account " # code # " " # a.name # " is archived and cannot be posted to.")));

      let debit = optMinor(raw, "debit");
      let credit = optMinor(raw, "credit");
      switch (debit, credit) {
        case (?_, ?_) return cb(#ok(errorResult("Line " # Nat.toText(idx) # " has both 'debit' and 'credit'. Each line carries exactly one.")));
        case (null, null) return cb(#ok(errorResult("Line " # Nat.toText(idx) # " has neither 'debit' nor 'credit', or the amount was not a whole number of minor units. 4500 means $45.00.")));
        case (?d, null) parsed.add({ account = a.id; side = #debit; minor = d; memo = optText(raw, "memo") });
        case (null, ?c) parsed.add({ account = a.id; side = #credit; minor = c; memo = optText(raw, "memo") });
      };
    };

    switch (postValidated(p, b, day, memo, Buffer.toArray(parsed), rate, parseRef(args), null)) {
      case (#err(m)) cb(#ok(errorResult(m)));
      case (#ok(e)) cb(#ok(okResult(Json.obj([
        ("message", Json.str("Posted entry #" # Nat.toText(e.seq) # " on " # fmtDate(e.day) # ".")),
        ("entry", entryToJson(e, b.baseCurrency)),
      ]))));
    };
  };

  // Shared by the three convenience recorders.
  func simplePost(
    p : Principal,
    b : Books,
    day : Int,
    memo : Text,
    debitAcct : Account,
    creditAcct : Account,
    minor : Nat,
    ref : ?Ref,
    cb : ToolCb,
    note : Text,
  ) {
    let lines : [Line] = [
      { account = debitAcct.id; side = #debit; minor = minor; memo = null },
      { account = creditAcct.id; side = #credit; minor = minor; memo = null },
    ];
    switch (postValidated(p, b, day, memo, lines, null, ref, null)) {
      case (#err(m)) cb(#ok(errorResult(m)));
      case (#ok(e)) cb(#ok(okResult(Json.obj([
        ("message", Json.str("Posted entry #" # Nat.toText(e.seq) # ": " # note)),
        ("entry", entryToJson(e, b.baseCurrency)),
      ]))));
    };
  };

  func recordInvoiceTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?amount = optMinor(args, "amount") else return cb(#ok(errorResult("Missing 'amount', or it was not a whole number of minor units. 45000 means $450.00.")));
    let ?invId = optText(args, "invoice_id") else return cb(#ok(errorResult("Missing 'invoice_id'.")));
    let day = switch (dayArgOr(args, "day", today())) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };

    let customer = switch (optText(args, "customer")) { case (?c) " — " # c; case (null) "" };
    let memo = "Invoice " # invId # customer;
    let ref : ?Ref = ?{ source = "invoice-desk"; id = invId; canister = optText(args, "canister") };

    // On cash basis, sending an invoice is not a bookable event. Say so rather
    // than posting nothing and reporting success.
    if (b.basis == #cash) {
      return cb(#ok(okResult(Json.obj([
        ("message", Json.str("Nothing posted: these books are on a cash basis, so income from invoice " # invId # " is recognized when the payment clears. Call record_payment then.")),
        ("posted", Json.bool(false)),
        ("basis", Json.str("cash")),
      ]))));
    };

    let arCode = switch (optText(args, "receivable_account")) { case (?c) c; case (null) receivableCode };
    let incCode = switch (optText(args, "income_account")) { case (?c) c; case (null) defaultIncomeCode };
    let ?ar = requireAccount(p, arCode, cb) else return;
    let ?inc = requireAccount(p, incCode, cb) else return;

    simplePost(p, b, day, memo, ar, inc, amount, ref, cb, "receivable " # fmtMinor(amount, b.baseCurrency) # " recognized as income on accrual basis.");
  };

  func recordPaymentTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?amount = optMinor(args, "amount") else return cb(#ok(errorResult("Missing 'amount', or it was not a whole number of minor units.")));
    let ?invId = optText(args, "invoice_id") else return cb(#ok(errorResult("Missing 'invoice_id'.")));
    let day = switch (dayArgOr(args, "day", today())) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };

    let cashCode = switch (optText(args, "cash_account")) { case (?c) c; case (null) defaultCashCode };
    let ?cash = requireAccount(p, cashCode, cb) else return;
    let ref : ?Ref = ?{ source = "invoice-desk"; id = invId; canister = optText(args, "canister") };
    let memo = "Payment received — invoice " # invId;

    switch (b.basis) {
      case (#accrual) {
        let arCode = switch (optText(args, "receivable_account")) { case (?c) c; case (null) receivableCode };
        let ?ar = requireAccount(p, arCode, cb) else return;
        simplePost(p, b, day, memo, cash, ar, amount, ref, cb, "cash up " # fmtMinor(amount, b.baseCurrency) # ", receivable cleared.");
      };
      case (#cash) {
        let incCode = switch (optText(args, "income_account")) { case (?c) c; case (null) defaultIncomeCode };
        let ?inc = requireAccount(p, incCode, cb) else return;
        simplePost(p, b, day, memo, cash, inc, amount, ref, cb, "cash up " # fmtMinor(amount, b.baseCurrency) # ", income recognized now (cash basis).");
      };
    };
  };

  func recordExpenseTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?amount = optMinor(args, "amount") else return cb(#ok(errorResult("Missing 'amount', or it was not a whole number of minor units.")));
    let ?memoIn = optText(args, "memo") else return cb(#ok(errorResult("Missing 'memo'.")));
    let day = switch (dayArgOr(args, "day", today())) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };

    let catCode = switch (optText(args, "category")) { case (?c) c; case (null) uncategorizedCode };
    let paidCode = switch (optText(args, "paid_from")) { case (?c) c; case (null) defaultCashCode };
    let ?cat = requireAccount(p, catCode, cb) else return;
    let ?paid = requireAccount(p, paidCode, cb) else return;
    if (cat.kind != #expense) return cb(#ok(errorResult("Category " # catCode # " " # cat.name # " is " # aKind(cat.kind) # " account, not an expense. Use post_entry if that is genuinely what you meant.")));

    let vendor = switch (optText(args, "vendor")) { case (?v) " — " # v; case (null) "" };
    let ref : ?Ref = switch (optText(args, "source")) {
      case (?s) ?{ source = s; id = switch (optText(args, "ref_id")) { case (?i) i; case (null) "" }; canister = null };
      case (null) null;
    };

    let tail = if (cat.code == uncategorizedCode) " Posted to 6900 Uncategorized — review will flag it until you classify it." else "";
    simplePost(p, b, day, memoIn # vendor, cat, paid, amount, ref, cb, fmtMinor(amount, b.baseCurrency) # " to " # cat.code # " " # cat.name # "." # tail);
  };

  func getEntryTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;
    let ?seq = optNat(args, "seq") else return cb(#ok(errorResult("Missing 'seq'.")));
    let ?e = getEntry(owner, seq) else return cb(#ok(errorResult("No entry #" # Nat.toText(seq) # " in these books.")));
    cb(#ok(okResult(Json.obj([("entry", entryToJson(e, b.baseCurrency))]))));
  };

  func listEntriesTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;

    let from = switch (optText(args, "from")) { case (?t) parseDayArg(t); case (null) null };
    let to = switch (optText(args, "to")) { case (?t) parseDayArg(t); case (null) null };
    let limit = switch (optNat(args, "limit")) { case (?n) n; case (null) 50 };
    let acctFilter = switch (optText(args, "account")) { case (?c) accountByCode(owner, c); case (null) null };
    let sourceFilter = switch (optText(args, "source")) { case (?s) ?lower(s); case (null) null };

    let all = ownerEntries(owner);
    let sorted = Array.sort<Entry>(all, func(x, y) { Nat.compare(y.seq, x.seq) });

    let rows = Buffer.Buffer<Json.Json>(16);
    for (e in sorted.vals()) {
      if (rows.size() < limit and inRange(e.day, from, to)) {
        let touchesAccount = switch (acctFilter) {
          case (?a) { Array.find<Line>(e.lines, func(l) { l.account == a.id }) != null };
          case (null) true;
        };
        let matchesSource = switch (sourceFilter) {
          case (?s) { switch (e.ref) { case (?r) lower(r.source) == s; case (null) false } };
          case (null) true;
        };
        if (touchesAccount and matchesSource) rows.add(entryToJson(e, b.baseCurrency));
      };
    };

    cb(#ok(okResult(Json.obj([
      ("count", Json.int(rows.size())),
      ("total_entries", Json.int(all.size())),
      ("entries", Json.arr(Buffer.toArray(rows))),
    ]))));
  };

  func reverseEntryTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?seq = optNat(args, "seq") else return cb(#ok(errorResult("Missing 'seq'.")));
    let ?reason = optText(args, "reason") else return cb(#ok(errorResult("Missing 'reason'. A correction with no stated cause is not much of a record.")));
    let ?orig = getEntry(p, seq) else return cb(#ok(errorResult("No entry #" # Nat.toText(seq) # " in your books.")));

    switch (orig.reversedBy) {
      case (?r) return cb(#ok(errorResult("Entry #" # Nat.toText(seq) # " was already reversed by #" # Nat.toText(r) # ".")));
      case (null) {};
    };

    // The reversal posts today, not on the original date — back-dating a
    // correction into a closed period is the thing closing exists to prevent.
    let day = today();
    let mirrored = Array.map<Line, Line>(orig.lines, func(l) { { l with side = switch (l.side) { case (#debit) #credit; case (#credit) #debit } } });

    switch (postValidated(p, b, day, "Reversal of #" # Nat.toText(seq) # " — " # reason, mirrored, orig.rate, orig.ref, ?seq)) {
      case (#err(m)) cb(#ok(errorResult(m)));
      case (#ok(rev)) {
        putEntry({ orig with reversedBy = ?rev.seq });
        cb(#ok(okResult(Json.obj([
          ("message", Json.str("Posted entry #" # Nat.toText(rev.seq) # " reversing #" # Nat.toText(seq) # " on " # fmtDate(day) # ". Both entries remain in the books, linked in each direction.")),
          ("entry", entryToJson(rev, b.baseCurrency)),
        ]))));
      };
    };
  };

  // --- TOOL IMPLEMENTATIONS: REPORTING ---

  func profitAndLossTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;

    let todayDay = today();
    let to = switch (dayArgOr(args, "to", todayDay)) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };
    let from = switch (dayArgOr(args, "from", fiscalYearStart(todayDay, b.fiscalYearStartMonth))) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };
    if (from > to) return cb(#ok(errorResult("'from' is after 'to'.")));

    let span = to - from;
    let priorTo = from - 1;
    let priorFrom = priorTo - span;

    let cur = balancesFor(owner, ?from, ?to);
    let prior = balancesFor(owner, ?priorFrom, ?priorTo);

    let incomeRows = Buffer.Buffer<Json.Json>(8);
    let expenseRows = Buffer.Buffer<Json.Json>(8);
    var income : Int = 0;
    var expense : Int = 0;
    var priorIncome : Int = 0;
    var priorExpense : Int = 0;

    for (a in sortedAccounts(owner, true).vals()) {
      let v = normalized(a.kind, balanceOf(cur, a.id));
      let pv = normalized(a.kind, balanceOf(prior, a.id));
      switch (a.kind) {
        case (#income) {
          income += v;
          priorIncome += pv;
          if (v != 0 or pv != 0) incomeRows.add(Json.obj([("code", Json.str(a.code)), ("name", Json.str(a.name)), ("amount_minor", Json.int(v)), ("amount", Json.str(fmtMinor(v, b.baseCurrency))), ("prior_minor", Json.int(pv))]));
        };
        case (#expense) {
          expense += v;
          priorExpense += pv;
          if (v != 0 or pv != 0) expenseRows.add(Json.obj([("code", Json.str(a.code)), ("name", Json.str(a.name)), ("amount_minor", Json.int(v)), ("amount", Json.str(fmtMinor(v, b.baseCurrency))), ("prior_minor", Json.int(pv))]));
        };
        case (_) {};
      };
    };

    let net = income - expense;
    let priorNet = priorIncome - priorExpense;

    cb(#ok(okResult(Json.obj([
      ("from", Json.str(fmtDate(from))),
      ("to", Json.str(fmtDate(to))),
      ("basis", Json.str(basisText(b.basis))),
      ("base_currency", Json.str(b.baseCurrency)),
      ("income", Json.arr(Buffer.toArray(incomeRows))),
      ("expenses", Json.arr(Buffer.toArray(expenseRows))),
      ("total_income_minor", Json.int(income)),
      ("total_income", Json.str(fmtMinor(income, b.baseCurrency))),
      ("total_expense_minor", Json.int(expense)),
      ("total_expense", Json.str(fmtMinor(expense, b.baseCurrency))),
      ("net_income_minor", Json.int(net)),
      ("net_income", Json.str(fmtMinor(net, b.baseCurrency))),
      ("prior_period", Json.obj([
        ("from", Json.str(fmtDate(priorFrom))),
        ("to", Json.str(fmtDate(priorTo))),
        ("net_income_minor", Json.int(priorNet)),
        ("net_income", Json.str(fmtMinor(priorNet, b.baseCurrency))),
      ])),
    ]))));
  };

  func balanceSheetTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;
    let asOf = switch (dayArgOr(args, "as_of", today())) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };

    let acc = balancesFor(owner, null, ?asOf);
    let assetRows = Buffer.Buffer<Json.Json>(8);
    let liabRows = Buffer.Buffer<Json.Json>(8);
    let equityRows = Buffer.Buffer<Json.Json>(8);
    var assets : Int = 0;
    var liabilities : Int = 0;
    var equity : Int = 0;

    for (a in sortedAccounts(owner, true).vals()) {
      let v = normalized(a.kind, balanceOf(acc, a.id));
      let row = Json.obj([("code", Json.str(a.code)), ("name", Json.str(a.name)), ("amount_minor", Json.int(v)), ("amount", Json.str(fmtMinor(v, b.baseCurrency)))]);
      switch (a.kind) {
        case (#asset) { assets += v; if (v != 0) assetRows.add(row) };
        case (#liability) { liabilities += v; if (v != 0) liabRows.add(row) };
        case (#equity) { equity += v; if (v != 0) equityRows.add(row) };
        case (_) {};
      };
    };

    // Income and expense accounts are never closed out to equity in v1, so
    // retained earnings is computed: everything earned less everything spent, up
    // to as_of. Without this line the accounting equation cannot hold.
    let retained = netIncome(owner, null, ?asOf);
    equityRows.add(Json.obj([
      ("code", Json.str("3900")),
      ("name", Json.str("Retained Earnings (computed)")),
      ("amount_minor", Json.int(retained)),
      ("amount", Json.str(fmtMinor(retained, b.baseCurrency))),
    ]));
    let totalEquity = equity + retained;
    let balances = assets == liabilities + totalEquity;

    cb(#ok(okResult(Json.obj([
      ("as_of", Json.str(fmtDate(asOf))),
      ("base_currency", Json.str(b.baseCurrency)),
      ("assets", Json.arr(Buffer.toArray(assetRows))),
      ("liabilities", Json.arr(Buffer.toArray(liabRows))),
      ("equity", Json.arr(Buffer.toArray(equityRows))),
      ("total_assets_minor", Json.int(assets)),
      ("total_assets", Json.str(fmtMinor(assets, b.baseCurrency))),
      ("total_liabilities_minor", Json.int(liabilities)),
      ("total_liabilities", Json.str(fmtMinor(liabilities, b.baseCurrency))),
      ("total_equity_minor", Json.int(totalEquity)),
      ("total_equity", Json.str(fmtMinor(totalEquity, b.baseCurrency))),
      ("balances", Json.bool(balances)),
      ("assertion", Json.str(if (balances) "Assets = Liabilities + Equity holds." else "BROKEN: assets " # fmtMinor(assets, b.baseCurrency) # " does not equal liabilities plus equity " # fmtMinor(liabilities + totalEquity, b.baseCurrency) # ". Run trial_balance — this should be impossible while every entry balances.")),
    ]))));
  };

  func trialBalanceTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;
    let asOf = switch (dayArgOr(args, "as_of", today())) { case (#ok(d)) d; case (#err(m)) return cb(#ok(errorResult(m))) };

    let acc = balancesFor(owner, null, ?asOf);
    let rows = Buffer.Buffer<Json.Json>(16);
    var totalDebit : Int = 0;
    var totalCredit : Int = 0;

    for (a in sortedAccounts(owner, true).vals()) {
      let dmc = balanceOf(acc, a.id);
      if (dmc != 0) {
        let d : Int = if (dmc > 0) dmc else 0;
        let c : Int = if (dmc < 0) -dmc else 0;
        totalDebit += d;
        totalCredit += c;
        rows.add(Json.obj([
          ("code", Json.str(a.code)),
          ("name", Json.str(a.name)),
          ("kind", Json.str(kindText(a.kind))),
          ("debit_minor", Json.int(d)),
          ("credit_minor", Json.int(c)),
          ("debit", Json.str(fmtMinor(d, b.baseCurrency))),
          ("credit", Json.str(fmtMinor(c, b.baseCurrency))),
        ]));
      };
    };

    let (grossD, grossC) = totalsFor(owner, null, ?asOf);
    let balanced = totalDebit == totalCredit;

    cb(#ok(okResult(Json.obj([
      ("as_of", Json.str(fmtDate(asOf))),
      ("base_currency", Json.str(b.baseCurrency)),
      ("accounts", Json.arr(Buffer.toArray(rows))),
      ("total_debits_minor", Json.int(totalDebit)),
      ("total_credits_minor", Json.int(totalCredit)),
      ("total_debits", Json.str(fmtMinor(totalDebit, b.baseCurrency))),
      ("total_credits", Json.str(fmtMinor(totalCredit, b.baseCurrency))),
      ("gross_posted_debits_minor", Json.int(grossD)),
      ("gross_posted_credits_minor", Json.int(grossC)),
      ("balanced", Json.bool(balanced)),
      ("proof", Json.str(if (balanced) "Total debits equal total credits. The books balance." else "OUT OF BALANCE by " # fmtMinor(totalDebit - totalCredit, b.baseCurrency) # ".")),
    ]))));
  };

  func accountLedgerTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;
    let ?code = optText(args, "account") else return cb(#ok(errorResult("Missing 'account'.")));
    let ?a = requireAccount(owner, code, cb) else return;

    let from = switch (optText(args, "from")) { case (?t) parseDayArg(t); case (null) null };
    let to = switch (optText(args, "to")) { case (?t) parseDayArg(t); case (null) null };
    let limit = switch (optNat(args, "limit")) { case (?n) n; case (null) 100 };

    // Opening balance is everything before the window.
    let opening : Int = switch (from) {
      case (?f) normalized(a.kind, balanceOf(balancesFor(owner, null, ?(f - 1)), a.id));
      case (null) 0;
    };

    let sorted = Array.sort<Entry>(ownerEntries(owner), func(x, y) { if (x.day == y.day) Nat.compare(x.seq, y.seq) else Int.compare(x.day, y.day) });

    let rows = Buffer.Buffer<Json.Json>(16);
    var running = opening;
    for (e in sorted.vals()) {
      if (inRange(e.day, from, to)) {
        for (l in e.lines.vals()) {
          if (l.account == a.id and rows.size() < limit) {
            let dmc : Int = switch (l.side) { case (#debit) l.minor; case (#credit) -l.minor };
            running += normalized(a.kind, dmc);
            rows.add(Json.obj([
              ("seq", Json.int(e.seq)),
              ("date", Json.str(fmtDate(e.day))),
              ("memo", Json.str(e.memo)),
              ("side", Json.str(sideText(l.side))),
              ("amount_minor", Json.int(l.minor)),
              ("amount", Json.str(fmtMinor(l.minor, b.baseCurrency))),
              ("running_balance_minor", Json.int(running)),
              ("running_balance", Json.str(fmtMinor(running, b.baseCurrency))),
            ]));
          };
        };
      };
    };

    cb(#ok(okResult(Json.obj([
      ("account", Json.str(a.code # " " # a.name)),
      ("kind", Json.str(kindText(a.kind))),
      ("opening_balance_minor", Json.int(opening)),
      ("closing_balance_minor", Json.int(running)),
      ("closing_balance", Json.str(fmtMinor(running, b.baseCurrency))),
      ("rows", Json.arr(Buffer.toArray(rows))),
    ]))));
  };

  // Chain minor units use the LEDGER's decimals; the books use cents. ckUSDC has
  // 6 decimals, so 1_000_000 on chain is 100 cents. Comparing the two raw is the
  // obvious way to get a confidently wrong reconciliation.
  func chainToCents(chainMinor : Nat, decimals : Nat) : Int {
    if (decimals <= 2) {
      var scaled = chainMinor;
      var i = decimals;
      while (i < 2) { scaled *= 10; i += 1 };
      scaled;
    } else {
      var div : Nat = 1;
      var i = 2;
      while (i < decimals) { div *= 10; i += 1 };
      chainMinor / div;
    };
  };

  func reconcileTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?code = optText(args, "account") else return cb(#ok(errorResult("Missing 'account'.")));
    let ?a = requireAccount(p, code, cb) else return;

    let ?link = a.linked else return cb(#ok(errorResult("Account " # code # " " # a.name # " is not linked to a ledger, so there is nothing on chain to compare it against. Call link_account first — returning a zero difference here would be a hollow answer.")));

    let bookBalance = normalized(a.kind, balanceOf(balancesFor(p, null, null), a.id));

    let ledger = ledgerOf(link.ledger);
    var symbol = "?";
    var decimals : Nat = 8;
    switch (Map.get(ledgerMeta, thash, link.ledger)) {
      case (?(s, d)) { symbol := s; decimals := d };
      case (null) {
        try {
          symbol := await ledger.icrc1_symbol();
          decimals := Nat8.toNat(await ledger.icrc1_decimals());
          Map.set(ledgerMeta, thash, link.ledger, (symbol, decimals));
        } catch (e) {
          return cb(#ok(errorResult("Could not read ledger metadata from " # link.ledger # ": " # Error.message(e) # ". Nothing was changed.")));
        };
      };
    };

    let chainRaw = try {
      await ledger.icrc1_balance_of({ owner = link.account; subaccount = link.subaccount });
    } catch (e) {
      return cb(#ok(errorResult("Ledger call failed: " # Error.message(e) # ". The stored reading was left untouched.")));
    };

    let chainCents = chainToCents(chainRaw, decimals);
    let diff = bookBalance - chainCents;

    // Entries posted since the last reconciliation are the explanation for a
    // difference, so they belong in the same response as the difference.
    let since = switch (link.lastReconciledAt) { case (?t) t; case (null) 0 };
    let recent = Buffer.Buffer<Json.Json>(8);
    for (e in ownerEntries(p).vals()) {
      if (e.postedAt > since and recent.size() < 25) {
        if (Array.find<Line>(e.lines, func(l) { l.account == a.id }) != null) {
          recent.add(Json.obj([("seq", Json.int(e.seq)), ("date", Json.str(fmtDate(e.day))), ("memo", Json.str(e.memo))]));
        };
      };
    };

    putAccount({ a with linked = ?{ link with lastChainMinor = ?chainRaw; lastReconciledAt = ?Time.now() } });

    cb(#ok(okResult(Json.obj([
      ("account", Json.str(a.code # " " # a.name)),
      ("ledger", Json.str(link.ledger)),
      ("symbol", Json.str(symbol)),
      ("book_balance_minor", Json.int(bookBalance)),
      ("book_balance", Json.str(fmtMinor(bookBalance, b.baseCurrency))),
      ("chain_balance_raw", Json.int(chainRaw)),
      ("chain_decimals", Json.int(decimals)),
      ("chain_balance_minor", Json.int(chainCents)),
      ("chain_balance", Json.str(fmtMinor(chainCents, b.baseCurrency))),
      ("difference_minor", Json.int(diff)),
      ("difference", Json.str(fmtMinor(diff, b.baseCurrency))),
      ("reconciled", Json.bool(diff == 0)),
      ("previously_reconciled_at_ns", switch (link.lastReconciledAt) { case (?t) Json.int(t); case (null) Json.nullable() }),
      ("entries_since_last_reconcile", Json.arr(Buffer.toArray(recent))),
      ("conversion", Json.str("Chain amounts are in " # Nat.toText(decimals) # " decimals; book amounts are in 2. Raw " # Nat.toText(chainRaw) # " converts to " # fmtMinor(chainCents, b.baseCurrency) # ".")),
    ]))));
  };

  func taxSummaryTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;

    let todayDay = today();
    let defaultStart = fiscalYearStart(todayDay, b.fiscalYearStartMonth);
    let from = switch (optNat(args, "year")) {
      case (?y) daysFromCivil(y, b.fiscalYearStartMonth, 1);
      case (null) defaultStart;
    };
    let to = addMonths(from, 12) - 1;
    let ratePct = switch (optFloat(args, "estimated_rate_pct")) { case (?r) r; case (null) 25.0 };

    let acc = balancesFor(owner, ?from, ?to);
    let incomeRows = Buffer.Buffer<Json.Json>(8);
    let expenseRows = Buffer.Buffer<Json.Json>(8);
    var income : Int = 0;
    var expense : Int = 0;
    var uncategorized : Int = 0;

    for (a in sortedAccounts(owner, true).vals()) {
      let v = normalized(a.kind, balanceOf(acc, a.id));
      switch (a.kind) {
        case (#income) { income += v; if (v != 0) incomeRows.add(Json.obj([("code", Json.str(a.code)), ("name", Json.str(a.name)), ("amount_minor", Json.int(v)), ("amount", Json.str(fmtMinor(v, b.baseCurrency)))])) };
        case (#expense) {
          expense += v;
          if (a.code == uncategorizedCode) uncategorized += v;
          if (v != 0) expenseRows.add(Json.obj([("code", Json.str(a.code)), ("name", Json.str(a.name)), ("amount_minor", Json.int(v)), ("amount", Json.str(fmtMinor(v, b.baseCurrency)))]));
        };
        case (_) {};
      };
    };

    let net = income - expense;
    let estimate : Int = if (net <= 0) 0 else Float.toInt(Float.fromInt(net) * ratePct / 100.0);
    let quarterly : Int = estimate / 4;

    let rules = Buffer.Buffer<Json.Json>(6);
    rules.add(Json.str("Period is the fiscal year starting " # fmtDate(from) # " and ending " # fmtDate(to) # ", from this books' fiscal year start month of " # Nat.toText(b.fiscalYearStartMonth) # "."));
    rules.add(Json.str("Basis is " # basisText(b.basis) # ": " # (if (b.basis == #cash) "income counted when payment cleared, expenses when paid." else "income counted when invoiced, expenses when incurred.")));
    rules.add(Json.str("Every account of kind 'expense' is treated as deductible in full. No account is excluded, no expense is apportioned, and no personal-use split is applied."));
    rules.add(Json.str("The quarterly estimate is simply net income multiplied by the " # fmtPct(ratePct) # "% rate you supplied, divided by four. It is arithmetic on an assumption you provided, not a computed tax liability."));
    rules.add(Json.str("Capital gains and losses on token holdings are NOT computed. Entries carry the exchange rate frozen at post time, which is the data a gains calculation would need, but v1 does not perform one."));
    if (uncategorized != 0) rules.add(Json.str("WARNING: " # fmtMinor(uncategorized, b.baseCurrency) # " is sitting in 6900 Uncategorized and is included in the expense total above. Classify it before relying on these numbers."));

    cb(#ok(okResult(Json.obj([
      ("fiscal_year_from", Json.str(fmtDate(from))),
      ("fiscal_year_to", Json.str(fmtDate(to))),
      ("basis", Json.str(basisText(b.basis))),
      ("income", Json.arr(Buffer.toArray(incomeRows))),
      ("expenses", Json.arr(Buffer.toArray(expenseRows))),
      ("total_income_minor", Json.int(income)),
      ("total_deductible_expense_minor", Json.int(expense)),
      ("net_income_minor", Json.int(net)),
      ("net_income", Json.str(fmtMinor(net, b.baseCurrency))),
      ("uncategorized_minor", Json.int(uncategorized)),
      ("assumed_rate_pct", Json.float(ratePct)),
      ("estimated_annual_minor", Json.int(estimate)),
      ("estimated_quarterly_minor", Json.int(quarterly)),
      ("estimated_quarterly", Json.str(fmtMinor(quarterly, b.baseCurrency))),
      ("rules_applied", Json.arr(Buffer.toArray(rules))),
      ("disclaimer", Json.str("This is a categorized summary of your own postings, not tax advice, and nothing here has been filed. A human or their accountant decides what these numbers mean.")),
    ]))));
  };

  func reviewTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?(owner, b) = requireReadableBooks(args, p, cb) else return;

    let todayDay = today();
    let nowNs = Time.now();
    let acc = balancesFor(owner, null, null);
    let findings = Buffer.Buffer<Json.Json>(8);

    func finding(severity : Text, kind : Text, detail : Text, fix : Text) {
      findings.add(Json.obj([("severity", Json.str(severity)), ("kind", Json.str(kind)), ("detail", Json.str(detail)), ("fix", Json.str(fix))]));
    };

    // 1. Trial balance. Should be impossible while every entry balances, which is
    //    exactly why it is worth asserting rather than assuming.
    let (gd, gc) = totalsFor(owner, null, null);
    if (gd != gc) finding("critical", "out_of_balance", "Total posted debits " # fmtMinor(gd, b.baseCurrency) # " do not equal total credits " # fmtMinor(gc, b.baseCurrency) # ".", "This should be impossible. Run trial_balance and report it.");

    // 2. Uncategorized.
    switch (accountByCode(owner, uncategorizedCode)) {
      case (?u) {
        let v = normalized(#expense, balanceOf(acc, u.id));
        if (v != 0) finding("high", "uncategorized", fmtMinor(v, b.baseCurrency) # " is sitting in " # uncategorizedCode # " Uncategorized.", "Run account_ledger on " # uncategorizedCode # " to see what, then reverse_entry and repost to a real category. close_period refuses while this is non-zero.");
      };
      case (null) {};
    };

    // 3. Linked accounts never reconciled, or gone stale.
    for (a in sortedAccounts(owner, false).vals()) {
      switch (a.linked) {
        case (?l) {
          switch (l.lastReconciledAt) {
            case (null) finding("medium", "never_reconciled", a.code # " " # a.name # " is linked to " # l.ledger # " but has never been reconciled.", "Run reconcile with account '" # a.code # "'.");
            case (?t) {
              let ageDays = (nowNs - t) / nanosPerDay;
              if (ageDays > staleReconcileDays) finding("low", "stale_reconcile", a.code # " " # a.name # " was last reconciled " # Int.toText(ageDays) # " days ago.", "Run reconcile with account '" # a.code # "'.");
            };
          };
        };
        case (null) {};
      };
    };

    // 4. Receivables outstanding.
    switch (accountByCode(owner, receivableCode)) {
      case (?ar) {
        let v = normalized(#asset, balanceOf(acc, ar.id));
        if (v > 0) {
          var oldest : ?Int = null;
          for (e in ownerEntries(owner).vals()) {
            if (Array.find<Line>(e.lines, func(l) { l.account == ar.id and l.side == #debit }) != null) {
              switch (oldest) { case (?o) { if (e.day < o) oldest := ?e.day }; case (null) oldest := ?e.day };
            };
          };
          let age = switch (oldest) { case (?o) todayDay - o; case (null) 0 };
          let sev = if (age > receivableOverdueDays) "medium" else "info";
          finding(sev, "receivables_outstanding", fmtMinor(v, b.baseCurrency) # " is outstanding in " # receivableCode # " Accounts Receivable; the oldest receivable posting is " # Int.toText(age) # " days old.", "Call record_payment as invoices settle.");
        };
      };
      case (null) {};
    };

    // 5. Is a period ready to close?
    let n = entryCount(owner);
    if (n > 0) {
      let fyStart = fiscalYearStart(todayDay, b.fiscalYearStartMonth);
      let priorEnd = fyStart - 1;
      let closed = switch (b.closedThrough) { case (?c) c; case (null) 0 };
      // Only worth mentioning if there is actually something in that period —
      // suggesting you close a year you never posted to is confident noise.
      var priorEntries = 0;
      for (e in ownerEntries(owner).vals()) { if (e.day <= priorEnd) priorEntries += 1 };
      if (priorEnd > closed and priorEntries > 0) {
        let uncat = switch (accountByCode(owner, uncategorizedCode)) { case (?u) normalized(#expense, balanceOf(balancesFor(owner, null, ?priorEnd), u.id)); case (null) 0 };
        if (uncat == 0) finding("info", "ready_to_close", "The fiscal year ending " # fmtDate(priorEnd) # " has nothing in Uncategorized and is ready to close.", "Call close_period with through '" # fmtDate(priorEnd) # "' and confirm true.") else finding("info", "close_blocked", "The fiscal year ending " # fmtDate(priorEnd) # " still has " # fmtMinor(uncat, b.baseCurrency) # " in Uncategorized.", "Classify it, then close_period.");
      };
    };

    if (n == 0) finding("info", "empty", "No entries have been posted yet.", "Post one with post_entry, or let record_invoice / record_expense do it.");

    cb(#ok(okResult(Json.obj([
      ("as_of", Json.str(fmtDate(todayDay))),
      ("entries", Json.int(n)),
      ("issues", Json.int(findings.size())),
      ("findings", Json.arr(Buffer.toArray(findings))),
      ("thresholds", Json.str("A reconciliation goes stale after " # Int.toText(staleReconcileDays) # " days; a receivable is called overdue after " # Int.toText(receivableOverdueDays) # " days.")),
    ]))));
  };

  func closePeriodTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?b = requireOwnBooks(p, cb) else return;
    let ?throughT = optText(args, "through") else return cb(#ok(errorResult("Missing 'through'.")));
    let ?through = parseDayArg(throughT) else return cb(#ok(errorResult("'" # throughT # "' is not a date.")));
    let confirm = switch (optBool(args, "confirm")) { case (?c) c; case (null) false };

    if (not confirm) return cb(#ok(errorResult("Closing is irreversible here — reopening a period is deliberately not a tool. Call again with confirm:true if you mean it.")));

    switch (b.closedThrough) {
      case (?c) { if (through <= c) return cb(#ok(errorResult("Books are already closed through " # fmtDate(c) # ", which is on or after " # fmtDate(through) # "."))) };
      case (null) {};
    };

    let blockers = Buffer.Buffer<Text>(4);
    let (gd, gc) = totalsFor(p, null, ?through);
    if (gd != gc) blockers.add("The trial balance through " # fmtDate(through) # " does not balance: debits " # fmtMinor(gd, b.baseCurrency) # " vs credits " # fmtMinor(gc, b.baseCurrency) # ".");

    switch (accountByCode(p, uncategorizedCode)) {
      case (?u) {
        let v = normalized(#expense, balanceOf(balancesFor(p, null, ?through), u.id));
        if (v != 0) blockers.add(fmtMinor(v, b.baseCurrency) # " is still in " # uncategorizedCode # " Uncategorized on or before " # fmtDate(through) # ". Closing books with unclassified expenses in them files a number you cannot defend.");
      };
      case (null) {};
    };

    if (blockers.size() > 0) {
      return cb(#ok(okResult(Json.obj([
        ("closed", Json.bool(false)),
        ("message", Json.str("Refused: " # Nat.toText(blockers.size()) # " thing(s) block closing through " # fmtDate(through) # ".")),
        ("blockers", Json.arr(Array.map<Text, Json.Json>(Buffer.toArray(blockers), Json.str))),
      ]))));
    };

    Map.set(books, phash, p, { b with closedThrough = ?through });
    cb(#ok(okResult(Json.obj([
      ("closed", Json.bool(true)),
      ("message", Json.str("Closed through " # fmtDate(through) # ". Nothing can post on or before that date now, including corrections — a reversal of an entry in a closed period posts today instead.")),
      ("closed_through", Json.str(fmtDate(through))),
    ]))));
  };

  // --- TOOL IMPLEMENTATIONS: SHARING ---

  func grantReaderTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?_ = requireOwnBooks(p, cb) else return;
    let ?who = optText(args, "principal") else return cb(#ok(errorResult("Missing 'principal'.")));
    let ?reader = parsePrincipal(who) else return cb(#ok(errorResult("'principal' is not a valid principal.")));
    if (reader == p) return cb(#ok(errorResult("You already own these books; granting yourself read access does nothing.")));
    let ?expT = optText(args, "expires") else return cb(#ok(errorResult("Missing 'expires'. Every grant has an end date — a permission with no expiry is one nobody revokes.")));
    let ?expires = parseDayArg(expT) else return cb(#ok(errorResult("'" # expT # "' is not a date. Use 'YYYY-MM-DD' or '+90'.")));
    if (expires < today()) return cb(#ok(errorResult("'expires' is in the past.")));

    let key = grantKey(p, reader);
    let existing = Map.get(grantsByKey, thash, key);
    Map.set(grantsByKey, thash, key, { owner = p; reader = reader; expiresDay = expires; note = optText(args, "note"); grantedAt = Time.now() });
    switch (existing) {
      case (null) Map.set(grantKeysByOwner, phash, p, Array.append(ownerGrantKeys(p), [key]));
      case (?_) {};
    };

    cb(#ok(okResult(Json.obj([
      ("message", Json.str(Principal.toText(reader) # " can read your books until " # fmtDate(expires) # ". Read-only: they cannot post, reverse, close, or grant.")),
      ("expires", Json.str(fmtDate(expires))),
    ]))));
  };

  func revokeReaderTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?who = optText(args, "principal") else return cb(#ok(errorResult("Missing 'principal'.")));
    let ?reader = parsePrincipal(who) else return cb(#ok(errorResult("'principal' is not a valid principal.")));
    let key = grantKey(p, reader);
    switch (Map.get(grantsByKey, thash, key)) {
      case (null) cb(#ok(errorResult("No grant to revoke for that principal.")));
      case (?_) {
        Map.delete(grantsByKey, thash, key);
        Map.set(grantKeysByOwner, phash, p, Array.filter<Text>(ownerGrantKeys(p), func(k) { k != key }));
        cb(#ok(okResult(Json.obj([("message", Json.str("Revoked. " # Principal.toText(reader) # " can no longer read your books."))]))));
      };
    };
  };

  func listReadersTool(_args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let todayDay = today();
    let rows = Buffer.Buffer<Json.Json>(4);
    for (k in ownerGrantKeys(p).vals()) {
      switch (Map.get(grantsByKey, thash, k)) {
        case (?g) rows.add(Json.obj([
          ("principal", Json.str(Principal.toText(g.reader))),
          ("expires", Json.str(fmtDate(g.expiresDay))),
          ("live", Json.bool(g.expiresDay >= todayDay)),
          ("note", optJsonText(g.note)),
          ("granted_at_ns", Json.int(g.grantedAt)),
        ]));
        case (null) {};
      };
    };
    cb(#ok(okResult(Json.obj([
      ("count", Json.int(rows.size())),
      ("readers", Json.arr(Buffer.toArray(rows))),
      ("note", Json.str("Grants are read-only and expire on their own. An expired grant is listed with live=false until you revoke it.")),
    ]))));
  };

  // --- SDK CONFIG & HTTP WIRING ---

  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = null;
    serverInfo = {
      name = "bookkeeping-ledger";
      title = "Bookkeeping Ledger";
      version = "0.1.0";
    };
    resources = [];
    resourceReader = func(uri) { Map.get(appContext.resourceContents, thash, uri) };
    tools = tools;
    toolImplementations = [
      ("setup_books", setupBooksTool),
      ("update_books", updateBooksTool),
      ("add_account", addAccountTool),
      ("list_accounts", listAccountsTool),
      ("archive_account", archiveAccountTool),
      ("link_account", linkAccountTool),
      ("post_entry", postEntryTool),
      ("record_invoice", recordInvoiceTool),
      ("record_payment", recordPaymentTool),
      ("record_expense", recordExpenseTool),
      ("get_entry", getEntryTool),
      ("list_entries", listEntriesTool),
      ("reverse_entry", reverseEntryTool),
      ("profit_and_loss", profitAndLossTool),
      ("balance_sheet", balanceSheetTool),
      ("trial_balance", trialBalanceTool),
      ("account_ledger", accountLedgerTool),
      ("reconcile", reconcileTool),
      ("tax_summary", taxSummaryTool),
      ("review", reviewTool),
      ("close_period", closePeriodTool),
      ("grant_reader", grantReaderTool),
      ("revoke_reader", revokeReaderTool),
      ("list_readers", listReadersTool),
    ];
    beacon = ?beaconContext;
  };

  transient let mcpServer = Mcp.createServer(mcpConfig);

  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      auth = ?authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) { mcpResponse };
      case (null) {
        if (req.url == "/") {
          // Query responses need certification on the non-raw gateway; punt to an
          // update call, which is exempt.
          {
            status_code = 204;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = ?true;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (await HttpHandler.http_request_update(ctx, req)) {
      case (?res) { res };
      case (null) {
        if (req.url == "/") {
          {
            status_code = 200;
            headers = [("Content-Type", "text/html")];
            body = Text.encodeUtf8("<h1>Bookkeeping Ledger MCP Server</h1><p>A double-entry ledger your agent posts to as money moves. Entries must balance or they are refused; nothing is ever edited or deleted, only reversed; and a cash account linked to an ICRC ledger can be reconciled against the chain. No money moves here — the only ledger call this canister makes is <code>icrc1_balance_of</code>. MCP endpoint at <code>/mcp</code>. Authenticate with an <code>x-api-key</code> header.</p>");
            upgrade = null;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };

  system func preupgrade() {
    stable_http_assets := HttpAssets.preupgrade(http_assets);
  };

  system func postupgrade() {
    HttpAssets.postupgrade(http_assets);
  };

  /// Mint a stable API key bound to the caller's principal.
  /// The raw key is returned once and never stored in plaintext.
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    return await ApiKey.create_my_api_key(authContext, msg.caller, name, scopes);
  };
};
