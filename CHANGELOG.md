# Changelog

All notable changes to Aegis: Courier are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses `MAJOR.MINOR.PATCH`. Anything below 1.0.0 is
pre-release development.

Releases that add a `.lua` file to the `.toc` are marked **restart** — the 1.12
client reads the file list at startup, so `/reload` is not enough.

## [0.2.0] - 2026-08-05

Stage B: mail actions and the auction ledger. No new `.lua` file, so this is a
`/reload`, **not** a client restart — the take engine lives in the existing
`core/inbox.lua` specifically to avoid forcing one.

### Added
- **Open All** — take gold and items, then delete the emptied mail. An
  event-driven state machine clocked by `MAIL_INBOX_UPDATE`, one action per
  step, modelled on TurtleMail's.
- **Take All** — take gold and items but keep the mail.
- **Delete Read** — delete read mail that is already empty. It will not touch
  anything still holding gold or an item, so it cannot destroy an attachment.
- **Right-click a mail** to take that one, reusing the same engine.
- Running gold/item total for the visit, and a chat summary when a run ends.
- **Auction ledger.** Collected sales are booked with gross price, the 5%
  consignment cut and the net, and mirrored to Aegis: Exchange when the seam
  is live.

### Behaviour worth knowing
- **Entries are finalized on collection, not arrival.** `take.Confirm` only
  credits money it can see has left the mail, so a take the server refused
  books nothing. This is also the dedupe: an emptied mail has nothing left to
  book, so re-visiting a mailbox cannot double-count and Courier needs no mail
  fingerprint at all. Two identical sales in the same hour therefore book as
  two entries — an arrival-fingerprint scheme would have merged them into one.
- **Only `Auction successful` mail books income.** `Outbid on …` mail carries
  the player's own returned bid; it is collected but never counted as a sale.
  `won` / `expired` / `cancelled` carry no price.
- **COD and GM mail are never taken**, in any mode or by right-click.
- A full bag stops a run (`ERR_INV_FULL`); a per-item cap
  (`ERR_ITEM_MAX_COUNT`) skips that mail and continues.
- A progress guard gives up on a mail the server will not hand over rather
  than looping on it.

### Changed
- `core/inbox.lua` now hosts the take engine (`A.take`) alongside the read
  layer (`A.inbox`). Stage A's header said this would be a new module; that
  would have added a `.toc` line and forced a full client restart, which is
  the cost Stage A's complete-module-set decision existed to avoid.
- `CLAUDE.md` gains six mail-mutation hard rules (14–19) covering delete
  safety, index shifting after a delete, progress guards, collection-time
  recording, sale classification and COD/GM handling.

### Fixed
- Escape now ends the mail session like the close button does. Previously it
  hid the window directly via `UISpecialFrames`, leaving the player at an open
  mailbox with both windows hidden.

### Tests
- Harness grows to **154 checks**, covering the take engine end to end:
  delete safety, index discipline after deletes, failed takes, outbid refunds,
  re-run idempotence, identical-sale separation, bag-full and item-cap paths,
  the wedge guard and the Aegis push.

## [0.1.0] - 2026-08-04 — **restart**

Stage A: the shell and the mailbox takeover. No mail is taken, deleted or
logged yet — see `ROADMAP.md` for what Stage B adds.

### Added
- Standalone Courier window parented to `UIParent`, with a saved per-character
  position, Escape-to-close, and Inbox / Ledger / Courier tabs.
- **Mailbox takeover** on `MAIL_SHOW`, replacing the Blizzard mail frame rather
  than overlaying it — the approach Aegis: Exchange uses for the auction house.
- Two-way hand-off: a **Blizzard UI** button on the Courier window, a
  **Courier** button on the stock mail frame, `/courier blizzard` for one
  visit, and a takeover off switch in the Courier tab.
- Read-only inbox list: the whole inbox in one scrolling view instead of the
  stock seven-per-page, with auction, returned and COD tagging, unread
  highlighting and a waiting-money summary.
- `core/db.lua` — `CourierDB` / `CourierCharDB`, settings, and a ledger whose
  entry shape is a superset of Aegis: Exchange's, so pushed entries are
  indistinguishable from Aegis's own.
- `core/bridge.lua` — the entire Aegis: Exchange integration surface. Dormant
  and silent until Aegis ships `RecordExternalTxn`.
- `core/inbox.lua` — read-only mailbox accessors, including auction-subject
  classification built from the client's own localized
  `AUCTION_*_MAIL_SUBJECT` globals rather than English literals, so it works on
  non-English clients.
- `util.SaleSplit` — gross / 5% consignment cut / net from the money attached
  to a sale mail.
- `tests/harness.lua` — off-client test harness stubbing the 1.12 API; 89
  checks over the load path, subject parsing, money maths and the takeover
  state machine. Run with `lua5.1 tests/harness.lua`.
- `docs/turtlemail-audit.md` — source audit of TurtleMail defining the
  replacement scope.
- `CLAUDE.md`, `ROADMAP.md`, `README.md`.

### Notes
- Dedupe keys are stored with a timestamp and pruned past 31 days, so the
  table cannot grow without bound.
- Courier takes over the mailbox, so run it **instead of** TurtleMail, not
  alongside it.

[0.2.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.2.0
[0.1.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.1.0
