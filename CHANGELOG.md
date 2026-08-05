# Changelog

All notable changes to Aegis: Courier are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses `MAJOR.MINOR.PATCH`. Anything below 1.0.0 is
pre-release development.

Releases that add a `.lua` file to the `.toc` are marked **restart** — the 1.12
client reads the file list at startup, so `/reload` is not enough.

## [0.5.0] - 2026-08-05

Return to sender, and a pass over the Courier tab's layout. `/reload`.

### Added
- **Return button on each inbox row.** Sends a mail back to its sender
  unopened. Money and Left move left to make room and the subject column
  narrows to suit.
- It only appears on mail that can actually be returned. The gate is
  `canReply` — the same header flag FrameXML uses to enable its own Reply
  button — so auction-house and system mail leave the column empty rather than
  offering a button the server would refuse.
- It also hides while a take run is in progress: `ReturnInboxItem` removes the
  mail and shifts every later index down one, exactly like a delete, which
  would desync the engine mid-run. `ui.ReturnMail` refuses in that state even
  if called directly.

### Fixed
- **The Courier tab's Integration heading was drawn on top of the log
  checkbox.** The heading was anchored to the *push* option, which was the last
  one when it was written; 0.4.0 added the log option below it and the heading
  did not move. It now anchors to the last option, with a rule between the two
  groups and more room throughout.
- The settings statistics line no longer reports "0 tracked mail ids". Stage B
  removed mail fingerprinting entirely, so `db.SeenCount()` is always zero and
  read as though something were broken. It now shows ledger and log counts,
  with correct singular/plural.

### Changed
- `CLAUDE.md` rule 15 extended: returning shifts indices like deleting, and
  return is gated on `canReply`.

### Tests
- Harness grows to **297 checks**, covering which mail offers Return, that the
  right sender receives it, that the inbox shrinks, and that Return is both
  hidden and refused during a run.

## [0.4.0] - 2026-08-05

Stage C.2: the correspondence log, plus three Send tab fixes from play testing.
No new `.lua` file, so this is a `/reload`.

### Added
- **Log tab.** Every mail Courier collects or sends, recorded with the
  participant, subject, attached item and money. Distinct from the Ledger next
  door: the Ledger is money (auction sales and the consignment split), the Log
  is correspondence.
- **Account-wide storage with the character on each entry**, where TurtleMail's
  log is per-character. That makes "this character only" a filter rather than a
  storage decision, and makes *"did I send that on my bank alt?"* answerable —
  the question people usually have.
- **One search box** matching participant, subject, item, auction tag and
  character, so `Bob`, `cloth` and `sold` all work. This covers both the
  participant and category filters the TurtleMail audit calls for without a
  dropdown widget.
- Received / Sent toggle, and a **Clear view** button that clears only the
  direction on screen.
- `logEnabled` setting in the Courier tab, **on** by default. TurtleMail
  defaults its log off; a log you have to know to switch on is one you never
  have when you want it. Both directions are capped at 250 entries.

### Behaviour worth knowing
- Entries are written on **collection** and on send **confirmation**, matching
  the ledger. A take the server refused, and a mail that failed to send, are
  not recorded.
- Delete-read logs nothing: an already-empty mail carries nothing worth
  recording.
- COD is logged as COD, never as attached gold.

### Fixed
- **Stray input box inside the mail body.** The body used `InputBoxTemplate`,
  whose border is 9-slice art built for a one-line box — it does not stretch
  with a tall multiline frame, so it stayed one line tall and rendered as an
  input-shaped rectangle floating in the body. The body now uses no template;
  we already draw our own well behind it.
- **Recipient suggestions no longer drop open on their own.** An empty
  recipient box matches every contact, so the list opened the moment the Send
  tab did and covered the form. It now appears once something is typed, and a
  dropdown button lists everyone on demand.
- **"on every mail" moved under the C.O.D. box** it modifies and greyed until
  C.O.D. is checked. It is also unchecked when disabled, so a greyed box cannot
  sit there checked and silently apply on the next send.

### Tests
- Harness grows to **285 checks**, covering the log end to end and the two
  Send tab behaviours above.
- **Fixed a harness bug that was hiding behaviour**, not just failing: the
  frame mock's catch-all `__index` returns a no-op function for any unknown
  key, including *data* fields, so `GetText()` on a box that had never had
  `SetText` called returned a function rather than nil. All mock accessors now
  read through `rawget`.

## [0.3.0] - 2026-08-05 — **restart**

Stage C.1: sending mail. **This release adds `core/send.lua` to the `.toc`, so
a full client restart is required** — 1.12 reads the file list at startup and
`/reload` will not pick it up.

### Added
- **Send tab.** Courier hides the Blizzard mail frame, so until now there was
  no way to send mail without handing the window back. Recipient, subject,
  body, gold, C.O.D. and a 12-slot attachment grid.
- **Multi-item send.** Vanilla mail carries one attachment per message, so a
  12-item send is 12 mails issued back to back, clocked by `MAIL_SEND_SUCCESS`.
  Subjects are numbered `subject [2/5]`; a blank subject names each mail after
  its item (`Silk Cloth (20)`).
- **True cost preview** — postage multiplied by the number of mails the batch
  will actually produce, which the stock UI cannot show because it never sends
  a batch.
- **Recipient autocomplete**, harvested from everyone who mails you (excluding
  the auction house and GMs) and every successful send, scoped per
  realm+faction and aged out after 30 days.
- **C.O.D. on the first mail or on every mail** of a batch.
- Attach by right-clicking an item in your bags or dragging it onto a slot;
  click a filled slot to remove it.

### Behaviour worth knowing
- **Attached gold rides the first mail only.** A 10-item send would otherwise
  send the same gold ten times. C.O.D. is a charge rather than a transfer, so
  it may repeat — but only when asked.
- **An unattachable item stops the batch before sending.** `GetSendMailItem()`
  is checked after the attach; if the stack moved, sold or is soulbound,
  `SendMail` would post an **empty** mail and leave the item behind. On abort
  the attachment list is preserved so the send can be retried.
- Bag right-click is only intercepted while the Send tab is open at a mailbox.
  Everywhere else it keeps its normal meaning.
- `MAIL_FAILED` aborts the batch and reports how many of the mails went out.

### Fixed
- Reclaim keyboard focus after each send. Blizzard's `MailFrame` is hidden but
  still receives `MAIL_SEND_SUCCESS`, and its `SendMailFrame_Reset()` calls
  `SetFocus()` on its own recipient box — which would have swallowed the next
  keystroke into an invisible frame.

### Changed
- `CLAUDE.md` gains five send hard rules (20–24): one attachment per mail, no
  `GetCursorInfo` on 1.12, verify the attach before sending, the C-vs-FrameXML
  split, and gold on the first mail only.
- `core/db.lua` stores contacts per realm+faction.

### Tests
- Harness grows to **233 checks**, adding the send engine end to end: batch
  numbering, auto-subjects, gold and C.O.D. placement, failed attaches,
  `MAIL_FAILED`, autocomplete matching and harvesting, and the bag right-click
  hook's scoping.

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

[0.5.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.5.0
[0.4.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.4.0
[0.3.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.3.0
[0.2.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.2.0
[0.1.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.1.0
