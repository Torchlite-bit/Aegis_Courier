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

## Stage B — mail actions and the ledger

The reason the addon exists. Everything here writes to `core/db.lua` and, when
the seam is live, mirrors through `core/bridge.lua`.

### B.1 Take engine
Event-driven state machine, one mail per `MAIL_INBOX_UPDATE`, modelled on
TurtleMail's (audit §1.1) — **not** a `for` loop, which desyncs from the server
and drops mail.

- **Open all**, **take all** (money + items, keep the mail) and **delete read**
  as three distinct actions. TurtleMail only has the first; splitting take from
  delete is a deliberate improvement.
- Always skip **COD** and **GM** mail.
- Abort on `ERR_INV_FULL`; skip-and-continue on `ERR_ITEM_MAX_COUNT`.
- Collected-gold readout, reset per mailbox visit.
- Right-click a row for the single-mail equivalent.

### B.2 Mail identity and dedupe
**Open — settle before any ledger write lands.** 1.12 has no mail GUID. The
candidate key is `sender|subject|money|arrival-bucket` where arrival derives
from the fractional `daysLeft` (`core/inbox.lua` already computes it).

Two identical stacks sold at the same price in the same hour **collide**, and a
collision silently *under*-counts. Decide the bucket width and the collision
policy first; `db.WasSeen` / `db.MarkSeen` are already in place to consume it.

### B.3 Auction matching and the money split
- Classify with the client's localized `AUCTION_*_MAIL_SUBJECT` globals —
  already implemented in `inbox.ClassifySubject`, already tested against a
  non-English format.
- `sold` → gross / 5% cut / net via `util.SaleSplit` (implemented, tested).
- `won` → a `buy` entry. `expired` / `cancelled` / `outbid` → no ledger entry,
  but worth surfacing in the list.

### B.4 Finalize on collection, not arrival
A ledger entry is written when the money/item is **actually taken**, never when
the mail is merely seen. This is the one behaviour Aegis's own scanner gets
wrong (it logs on `MAIL_INBOX_UPDATE`), and matching it would be a bug, not
compatibility.

### B.5 Push to Aegis
Mirror each finalized entry through `bridge.Push`. Already written and tested
against a stub; it goes live by itself the moment Aegis ships
`RecordExternalTxn`. Nothing in B.5 should need writing — verify, don't build.

---

## Stage C — send mail and the log

- Multi-item send: attachment grid, one mail per item, `[i/n]` subjects,
  true multi-mail cost preview (audit §3).
- Recipient autocomplete, harvested from inbox senders and successful sends,
  aged out after 30 days.
- COD on first / every mail.
- Mail log (sent + received) with participant and category filters.
  Deliberately **not** porting TurtleMail's bundled calendar date-picker.
- pfUI skin, every call `pcall`-guarded so a pfUI API change can only cost the
  default look.

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
