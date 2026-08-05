# Roadmap

Staged, dependency ordered. Each stage ships something usable on its own.
Scope for the TurtleMail-replacement items is pinned to
[`docs/turtlemail-audit.md`](docs/turtlemail-audit.md) — that table is the
source of truth for what "similar to TurtleMail" means, not memory.

---

## Stage A — shell and takeover ✅

Landed in 0.1.0.

- Standalone window under `UIParent`, saved position, Escape-closable.
- Mailbox takeover on `MAIL_SHOW`, replace-don't-overlay, with both 1.12
  silent-failure traps handled (see `CLAUDE.md` rules 11–12).
- Two-way hand-off: **Blizzard UI** button on ours, **Courier** button on
  theirs, plus a takeover off switch.
- Read-only inbox list — full inbox in one scroll, auction/returned/COD tags.
- Ledger and settings tabs; DB, dedupe primitives and the Aegis seam in place.
- Off-client test harness (`tests/harness.lua`).

---

## Stage B — mail actions and the ledger ✅

Landed in 0.2.0. Engine lives in `core/inbox.lua` as `A.take` (no new `.toc`
line, so no forced client restart).

- **B.1 Take engine** — event-driven state machine clocked by
  `MAIL_INBOX_UPDATE`, one action per step. Open All / Take All / Delete Read,
  plus right-click for a single mail. COD and GM mail always skipped.
  `ERR_INV_FULL` stops a run, `ERR_ITEM_MAX_COUNT` skips the mail. A
  change-based progress guard stops a mail the server will not hand over from
  wedging the run. Collected-gold readout and a chat summary.
- **B.2 Mail identity** — **resolved by removing the problem.** No fingerprint.
  Recording on collection means an emptied mail has nothing left to book, so a
  re-scan is inert and two identical sales stay two entries. The
  arrival-bucket key was rejected: no bucket width is both stable across a
  relog and fine enough to separate a bulk seller's identical sales, and a
  collision silently *under*-counts. `db.WasSeen` / `db.MarkSeen` remain in the
  DB as unused primitives. See `docs/turtlemail-audit.md`.
- **B.3 Auction matching and the money split** — localized
  `AUCTION_*_MAIL_SUBJECT` classification; `sold` books gross / 5% cut / net.
  Only `sold` books income: `outbid` money is the player's own returned bid,
  and `won` / `expired` / `cancelled` carry no price.
- **B.4 Finalize on collection** — `take.Confirm` fails closed, crediting only
  money it can see has left the mail.
- **B.5 Push to Aegis** — verified against a stub; goes live by itself when
  Aegis ships `RecordExternalTxn`.

Deliberately not done in B: nothing writes the mail **log** (Stage C), and a
mail collected through the *stock* Blizzard window is not seen by the ledger,
since Courier only books what its own engine takes.

---

## Stage C — send mail and the log

### C.1 Send tab ✅
Landed in 0.3.0 (**restart** — adds `core/send.lua`).

- Multi-item send: 12-slot attachment grid, one mail per item, `[i/n]`
  subjects, blank-subject auto-naming, true multi-mail postage preview.
- Recipient autocomplete harvested from inbox senders and successful sends,
  scoped per realm+faction, aged out after 30 days.
- C.O.D. on the first mail or every mail; attached gold on the first only.
- Attach by bag right-click (scoped to the Send tab at a mailbox) or drag.
- Aborts before sending if an item will not attach, preserving the list.

### C.2 Mail log — next
Sent + received log with participant and category filters (audit §4). The
auction ledger already covers sales; this is general correspondence.
Deliberately **not** porting TurtleMail's bundled calendar date-picker.

Open question to settle first: whether the log is per-character (TurtleMail's
choice) or account-wide. Per-character matches expectations but makes "did I
send that on my bank alt?" unanswerable, which is the common real question.

### C.3 pfUI skin — planned
Every call `pcall`-guarded so a pfUI API change can only cost the default look.

---

## Deferred / decided against

- **Reading anything from Aegis: Exchange.** One-directional by design; see
  `CLAUDE.md`, integration rules.
- **Disabling Aegis's own mail scanner from our side.** Aegis stands itself
  down when it detects Courier (its Phase 0.2). We do not reach into it.
- **Calendar date-picker** for log filtering — a whole bundled widget for one
  filter. Revisit if asked.
- **Declaring Aegis in the `.toc`** as an optional dependency. `bridge.Ready()`
  re-checks at call time instead, so load order cannot matter.
