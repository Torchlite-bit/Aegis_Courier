# Changelog

All notable changes to Aegis: Courier are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses `MAJOR.MINOR.PATCH`. Anything below 1.0.0 is
pre-release development.

Releases that add a `.lua` file to the `.toc` are marked **restart** — the 1.12
client reads the file list at startup, so `/reload` is not enough.

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

[0.1.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.1.0
