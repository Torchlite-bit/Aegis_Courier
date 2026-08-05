# TurtleMail feature audit

**Purpose.** "Convenient mailbox features similar to TurtleMail" is the stated
scope for Aegis: Courier. This document replaces that phrase with a concrete,
sourced inventory of what TurtleMail actually does, so Courier's scope is a
decision rather than a memory.

**Method.** Read-only audit of the TurtleMail source at
[`sica42/TurtleMail`](https://github.com/sica42/TurtleMail) (v1.4.5,
`TurtleMail.lua` ~1730 lines + `TurtleMail.xml` ~1900 lines), cross-checked
against the 1.12.1 `FrameXML` (`MailFrame.lua`, `MailFrame.xml`,
`GlobalStrings.lua`) from
[`MOUZU/Blizzard-WoW-Interface`](https://github.com/MOUZU/Blizzard-WoW-Interface).
No code was copied; the entries below describe behaviour and mechanism.

TurtleMail is an **extension** of the Blizzard mail UI — it hooks and decorates
`MailFrame` in place. Courier **replaces** that window instead (see
`CLAUDE.md`), so every feature below is re-implemented against our own frames,
not inherited.

---

## 1. Inbox automation

### 1.1 Open-all ("Open Mail" button)

The headline feature. A single `UIPanelButtonTemplate` button anchored into
`InboxFrame` drives a **state machine**, not a loop:

- `inbox_open_all()` sets `inbox_opening = true`, `inbox_index = 1`,
  `inbox_update = true`.
- Each `OnUpdate` tick, if `inbox_update` is set, it processes **exactly one**
  mail then clears the flag.
- Processing a mail is `GetInboxText(i)` → `TakeInboxMoney(i)` →
  `TakeInboxItem(i)` → `DeleteInboxItem(i)`, in that order.
- The next `MAIL_INBOX_UPDATE` event re-arms `inbox_update`, which advances the
  index. **The server's own inbox refresh is the clock** — there is no timer
  and no fixed delay.
- Termination: `inbox_index > GetInboxNumItems()`, at which point it prints the
  total gold collected and calls `inbox_abort()`.

This is the design worth copying. A naive `for i = 1, n do ... end` loop
desyncs from the server and drops mail; driving off `MAIL_INBOX_UPDATE` is what
makes it reliable, and it is why the addon can be described as "very rapid"
without being throttled.

**Skips, deliberately:**

| Condition | Source | Behaviour |
|---|---|---|
| `COD > 0` | header field 6 | skipped, always — never auto-pays a COD |
| `isGM` | header field 13 | skipped |
| `inbox_skip` flag | set by error handler | skips the current index |

**Abort conditions** (`UI_ERROR_MESSAGE`): `ERR_INV_FULL` aborts the whole run;
`ERR_ITEM_MAX_COUNT` sets `inbox_skip` so the run continues past the one item
that can't fit.

**Visual lock:** while running, all seven `MailItem*ButtonIcon` textures are
desaturated and their check state cleared, so the inbox reads as "busy".

### 1.2 Right-click a single mail

`InboxFrame_OnClick` is hooked. A right-click runs the same
money → item → delete sequence for that one mail (`inbox_open(i, manual)`),
again skipping COD. Left-click keeps the stock "open in `OpenMailFrame`"
behaviour.

### 1.3 Passive inbox refresh

`on_update` counts down a 200-tick timer and calls `CheckInbox()` when it
expires (and only while not mid-open). This is the pacing to match — see
`CLAUDE.md` rule 13.

### 1.4 Collected-gold readout

`update_money()` accumulates `money_received` across the session and renders it
into a `MoneyReceived` FontString on the mail frame, reset on `MAIL_SHOW`. On
completion it also prints the total to chat.

---

## 2. Inbox decoration

- **Auction-house icon.** On `MAIL_INBOX_UPDATE`, each of the 7 visible rows
  gets a `TurtleMailAuctionIcon{i}` shown when the sender is in a hardcoded
  set: `Stormwind / Alliance / Darnassus / Undercity / Thunder Bluff  /
  Horde / Blackwater Auction House`. Note the **double space** in
  `"Thunder Bluff  Auction House"` — that is verbatim in the source and is
  either a server-side quirk or a latent bug; Courier should match on a
  normalized sender string rather than reproduce it.
- **Returned-mail arrow.** `TurtleMailReturnedArrow{i}` shown from
  `wasReturned` (header field 10).
- Both icons are tinted `NORMAL_FONT_COLOR`.
- Row indices here **are** page-derived (`i + (pageNum - 1) * 7`) because these
  decorate the 7 visible Blizzard rows. That is a display concern only — see
  `CLAUDE.md` rule 9.

---

## 3. Send-mail enhancements

This is roughly half the addon and the part most easily under-scoped.

- **Multi-item attachment.** Vanilla `SendMail` has **exactly one** attachment
  slot. TurtleMail fakes many by keeping an attachment list
  (`ATTACHMENTS_MAX = 21`, laid out over up to 3 rows) and **sending one mail
  per item**, sequentially, driven by `MAIL_SEND_SUCCESS`. Subjects get a
  ` [i/n]` suffix when more than one mail results.
- **Auto-subject.** An empty subject becomes the item name plus stack count
  (`"Silk Cloth (20)"`), or `<No attachments>` for a bodiless mail.
- **Cost preview.** `SendMailCostMoneyFrame` shows
  `GetSendMailPrice() * max(1, numAttachments)` — the true multi-mail cost.
- **COD on 1st / each mail.** A `SendMailCODAllButton` toggle decides whether
  the COD amount applies only to the first mail of a batch or to every one; the
  money label is rewritten to say which.
- **Recipient autocomplete.** Names are harvested from two places — every
  `GetInboxHeaderInfo` call where `canReply` is set (i.e. anyone who mails you),
  and every successful send — into
  `TurtleMail_AutoCompleteNames[realm .. "|" .. faction]`, stored as
  `name -> GetTime()`. Entries older than **30 days** are pruned at
  `PLAYER_LOGIN`. A dropdown of matches supports arrow-key cycling and
  tab-completion against `MAIL_AUTOCOMPLETE_MAX_BUTTONS` buttons.
- **Drag / right-click to attach.** `PickupContainerItem`, `UseContainerItem`,
  `SplitContainerItem` and `GetContainerItemInfo` are all hooked so a
  right-click or drag from a bag adds to the attachment list (and to the trade
  frame elsewhere).
- The stock single `SendMailPackageButton` is disabled and stripped, replaced
  by the addon's own grid.

---

## 4. Mail log

Off by default; enabled with `/tm log`. Adds a third tab (`MailFrameTab3`).

- Two logs, `Sent` and `Received`, in `TurtleMail_Log` (per character).
- Entry shape: `timestamp, participant, subject, money, cod, icon, item,
  returned, gm, ah`.
- **Auction classification** is the notable part. Rather than hardcoding
  English, it matches the subject against the client's own localized globals,
  stripping the `%s` placeholder first:

  ```
  string.find(subject, string.gsub(AUCTION_SOLD_MAIL_SUBJECT, "%%s", ""))
  ```

  mapping to `ah = "Sold" | "Removed" | "Expired" | "Won" | "Outbid"`.

  All five globals are confirmed present in 1.12.1 `GlobalStrings.lua`:

  | Global | enUS value |
  |---|---|
  | `AUCTION_SOLD_MAIL_SUBJECT` | `Auction successful: %s` |
  | `AUCTION_WON_MAIL_SUBJECT` | `Auction won: %s` |
  | `AUCTION_EXPIRED_MAIL_SUBJECT` | `Auction expired: %s` |
  | `AUCTION_REMOVED_MAIL_SUBJECT` | `Auction cancelled: %s` |
  | `AUCTION_OUTBID_MAIL_SUBJECT` | `Outbid on %s` |

- Filtering: by participant (dropdown of everyone seen), by category
  (AH / Returned / GM / …), and by date through a bundled `Calendar.lua`
  date-picker.
- `/tm clear sent`, `/tm clear received`, `/tm clear names` maintenance
  commands.

---

## 5. Other

- **Frame position** is saved per character (`TurtleMail_Point`) and the mail
  frame is made draggable.
- **pfUI skinning** via a `pfui_skin()` path, applied when pfUI is present.
- **Localization** stubs for de / es / fr / ru with a `setmetatable`
  `__index` fallback that returns the key itself.
- **`/tm debug`** toggles verbose tracing.
- SavedVariables: `TurtleMail_AutoCompleteNames` (account),
  `TurtleMail_To` / `TurtleMail_Point` / `TurtleMail_Log` (per character).

---

## 6. What TurtleMail does NOT do

Relevant because it marks where Courier goes beyond a like-for-like
replacement:

- **No money maths on auction mail.** It labels a mail `Sold`, but never
  derives the gross sale price, the 5% consignment cut, or net proceeds. The
  logged `money` is whatever was attached.
- **No dedupe / stable mail identity.** The log appends on the *action* of
  opening, so it happens to avoid double-counting, but there is no mail id and
  no `WasSeen` equivalent. Re-scanning an inbox would double-count.
- **No collection-vs-arrival distinction** in any ledger sense — there is no
  ledger, only a log.
- **No item identity beyond a name/texture** — correct, since 1.12 has no
  `GetInboxItemLink` (`CLAUDE.md` rule 10).
- **Extends rather than replaces** the Blizzard window, so it inherits the
  7-row pagination and the stock layout.

---

## 7. Scope decisions for Courier

Derived from the above. "Carry over" means re-implement the behaviour against
Courier's own window.

| # | Feature | Decision | Stage |
|---|---|---|---|
| 1.1 | Open-all as an event-driven state machine | **Carry over** — including the COD/GM skips and the `ERR_INV_FULL` / `ERR_ITEM_MAX_COUNT` handling | B |
| 1.2 | Right-click single-mail take | Carry over | B |
| 1.3 | Passive `CheckInbox()` pacing | Carry over (~200 ticks) | B |
| 1.4 | Collected-gold readout | Carry over | B |
| — | **Take-all (money+items, keep mail)** | **New** — TurtleMail always deletes; split take from delete | B |
| — | **Delete-read** | **New** — explicit, separate action | B |
| 2 | AH / returned row markers | Carry over, sender matched normalized | A (display) / B |
| 3 | Multi-item send, autocomplete, COD modes | Carry over | C |
| 4 | Mail log | Carry over, superseded by the ledger for AH mail | C |
| 4 | Localized `AUCTION_*_MAIL_SUBJECT` matching | **Carry over — and this is the correct approach.** Aegis: Exchange's own scanner hardcodes the English `"Auction successful: "`; Courier should not repeat that | B |
| 5 | Saved frame position, pfUI skin | Carry over | A / C |
| 6 | Sale price / 5% cut / net proceeds | **New** — Courier's reason to exist | B |
| 6 | Stable per-mail id + dedupe | **New** — `WasSeen`/`MarkSeen` equivalent | B |
| 6 | Finalize on **collection**, not arrival | **New** | B |
| — | Calendar date-picker for log filtering | **Drop for now** — a whole bundled widget for one filter; revisit if asked | — |

### Note on mail identity — **resolved in Stage B**

TurtleMail offers nothing to copy here, and it looked like the hardest problem
in the Courier design: **1.12 has no mail GUID**. The available raw material is
`sender`, `subject`, `money`, `CODAmount`, `daysLeft` (fractional days), and
`hasItem`. `daysLeft` decreases in real time while `time()` increases, so
`time() - (30 - daysLeft) * 86400` is an approximately **stable arrival
timestamp** — which is the trick Aegis: Exchange already uses, bucketed to the
hour.

**That approach was rejected.** It is an approximation, not an identity: two
identical stacks sold at the same price in the same hour collide, and a
collision silently *under*-counts, which is worse than a visible failure. There
is no bucket width that is both stable enough to survive a relog and fine
enough to separate a bulk seller's identical sales.

The problem dissolves once entries are finalized on **collection** rather than
arrival — which the design already required for its own reasons. After
`TakeInboxMoney` succeeds the mail's `money` is `0`, so a re-scan on any later
visit finds nothing to book. The mailbox state *is* the dedupe.

So Courier has **no mail fingerprint at all**. `db.WasSeen` / `db.MarkSeen`
remain in the DB as primitives but are unused by the take engine. The
guarantees this buys, all covered by `tests/harness.lua`:

- a second pass over an already-collected inbox books nothing;
- two identical sales in the same hour book as **two** entries;
- a take the server refused books **nothing** (`take.Confirm` fails closed —
  it only credits money it can see has left the mail).
