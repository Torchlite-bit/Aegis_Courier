# Changelog

All notable changes to Aegis: Courier are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses `MAJOR.MINOR.PATCH`. 1.0.0 is the first complete
release; everything below it was pre-release development.

Releases that add a `.lua` file to the `.toc` are marked **restart** — the 1.12
client reads the file list at startup, so `/reload` is not enough.

## [1.6.1]

### Fixed
- **The status line at the bottom of the window was drawn over.** The recessed
  plate the panels sit on ended 16px from the bottom edge while the footer text
  sat at 14 — so the plate covered the top half of "At mailbox | linked to
  Aegis: Exchange". The plate's bottom is now derived from where the footer
  actually is rather than from a number that looked about right, and the test
  suite asserts the two cannot overlap again.

## [1.6.0]

The window resizes and scales, sent mail sits on a recessed plate like
Exchange's, gold is entered in three boxes with coin icons, and the Sent
reader's message box is back to a sensible height. `/reload`.

### Added
- **Drag the bottom-right corner to resize the window.** A taller window shows
  more mail — anywhere from 8 rows at the smallest to 25 at the largest — and
  the size is remembered per character. Vanilla frames never reflow, so extra
  height genuinely means extra rows rather than more empty space.
- **Window scale**, in the Courier tab: minus, plus and reset between 70% and
  150%, remembered per character. Scale and size answer different questions —
  a bigger window shows *more*, scale makes the same window *larger* — and on
  a big screen you want both.
- **Gold is now three boxes with coin icons** instead of one box you type
  `12g 30s` into, matching Exchange. Tab walks through them like any other
  field.

### Changed
- **The panels sit on a recessed plate**, matching Exchange's content well.
  With the outer frame already shared, this was the remaining reason the two
  addons read as unrelated windows.
- **The Sent reader's message box is shorter again** — 150px rather than the
  204px of v1.5.0, which was too tall and read as a large empty box. It grows
  with the window up to that point and no further, because a stored message is
  capped at 500 characters and anything past ~150px is blank space rather than
  more text.

### Fixed
- The window's minimum height is now derived from the **Sent reader**, not the
  inbox list. The reader has a fixed header, item grid and button strip, so
  sizing to the list alone left its message box 36px tall at the smallest
  window — laid out correctly and completely unusable.

## [1.5.0]

The window now matches Aegis: Exchange, the Sent reader gives the message room
to breathe, and **Tab** moves between fields when composing. `/reload`.

### Changed
- **The window wears Exchange's frame.** Unskinned, Courier used a thin tooltip
  border throughout while Exchange used the heavier ornamental dialog frame, so
  running both looked like running two unrelated addons. Courier now uses the
  same frame, title inset and title size. (With pfUI installed the two already
  matched — that path is untouched.)
- **The inbox shows 12 mails at a time, up from 10.** The window grew for the
  heavier frame and the taller message area anyway, and the list is sized from
  the window rather than the other way round.
- **The Sent reader's message area is more than twice as tall** — 204px, up
  from 92px. The item list moved from two columns of six to three of four,
  which still shows every item a batch can hold (12 is the cap) while giving
  132px back to the message. The mail count and item count now share one line
  instead of two.

### Added
- **Tab moves to the next field when composing** — To → Subject → Body → Gold,
  wrapping back to To. This is how the stock mail form behaves. Tab inside the
  message no longer types a tab character.

## [1.4.0]

Sent mail gets its own tab with a reader, the Send tab is now **Compose**, and
every batch reports how long it took. `/reload`.

### Added
- **A Sent tab.** Sent mail moves out of the Log tab into its own, and works
  like the Inbox: a list of sends, click one to read it. The reader shows the
  recipient, your subject, when it went, which character sent it, every item
  with its icon and stack size, the gold or COD attached, the message body,
  and how many mails the send actually cost you in postage.
- **Compose to ‹recipient›** from inside a sent record, which switches to the
  Compose tab with the name already filled in.
- Every batch now reports its own elapsed time — `sent 12 mails to Torchbank
  in 4.2s` — so "did that get faster?" has an answer instead of an impression.

### Changed
- **The Send tab is now called Compose.** "Send" and "Sent" side by side read
  as two views of one thing, which they are not: one is the form you write in,
  the other is what already went. Only the label changed — the tab you had
  selected is still remembered correctly across the update.
- **The Log tab is received-only.** It no longer carries a Sent/Received
  toggle, so each kind of mail lives in exactly one place.

### Notes
- A sent mail is **gone from the client** — vanilla has no sent-items store and
  no way to read back a mail you sent. So the Sent tab replays what Courier
  recorded as you sent, and there is deliberately no Take or Return: there is
  nothing left to act on.
- For the same reason, sends recorded before this update have **no message
  body and no item icons** — nothing can recover them. Those records still
  open and read correctly, just without those two things.

## [1.3.0]

Mass sends are faster, and the Log tab's **Sent** side is now a proper sent
box: one row per send, with the items it carried, kept for 30 days. `/reload`.

### Changed
- **Mass sending no longer pauses between mails.** Courier waited a fixed 0.3
  seconds after every mail, which on a 12-item send is 3.6 seconds of pure
  waiting. That pause was added when a single refusal threw the whole batch
  away, so over-paying to avoid a race made sense. It no longer does: refusals
  are retried per mail, and the attach path now waits for busy stacks and
  re-finds moved ones instead of trusting a stale bag slot. Every batch now
  starts at full speed and only slows down if the server actually refuses
  something — and each send starts optimistic again rather than inheriting the
  last one's caution.
  - **How much faster in practice is not yet known.** An earlier draft of this
    entry claimed "roughly three times faster"; that was arithmetic, not a
    measurement, and it assumed a server round-trip we do not control. The
    3.6 seconds is real and is gone, but each mail still costs a round-trip,
    so on a short send the difference may be hard to notice at all. v1.4.0
    makes every batch report its own elapsed time so this stops being a matter
    of impression.

### Added
- **A sent box.** The Log tab's **Sent** side now shows one row per *send*
  rather than one per mail, with the recipient, your subject, the items that
  went, and how many mails it actually cost. Vanilla mail carries one
  attachment, so mailing 12 items to a bank alt is 12 separate mails and the
  game has no idea they belong together — that grouping is Courier's, recorded
  as you send because it cannot be recovered afterwards.
- Records are kept for **30 days**, with a 500-send ceiling as well, so a heavy
  bank-alt week cannot quietly turn your SavedVariables into something that
  takes seconds to load. Ageing out happens at login.
- The find box searches **every** item in a send, not just the ones that fit on
  the row — "did I mail that?" is the whole point of having this.
- A send is recorded only once the server confirms a mail, so a batch that got
  nothing out leaves no record, and one abandoned halfway records exactly what
  actually went.

## [1.2.0]

Fixes mass sends halting partway with "could not attach". `/reload`.

### Fixed
- **A mass send stopped dead at the first item it could not attach**, printing
  `could not attach [item] -- send stopped` and abandoning everything still
  queued. Three separate faults were behind it.
  - **We never read the slot's lock flag.** `GetContainerItemInfo` returns
    `texture, itemCount, locked, …`, and Courier read only the first two.
    `PickupContainerItem` on a slot the server has locked does *nothing at
    all* — no error, no event — so the attach silently posted nothing and the
    run gave up. The lock is normal: the previous mail's bag update simply had
    not landed yet, which is why this hit long sends and bad connections
    hardest. Courier now waits for the lock to clear instead of failing.
  - **The bag coordinates were a snapshot.** An attachment remembers where it
    was when you queued it, and on a twelve-item send that can be a minute and
    eleven mails out of date. Anything that reshuffles your bags in between
    invalidated it. Courier now re-finds a moved stack by name.
  - **One bad item cost the whole queue.** Now it costs one item: the rest of
    the batch goes out and you are told what was skipped, rather than the run
    stopping and leaving you to rebuild a twelve-item list by hand.
- **A mass send could post the WRONG item.** The old check asked only whether
  *something* was attached, never whether it was the thing you queued. If a
  different stack had moved into the remembered slot, that check passed and the
  replacement went to the recipient silently — a worse outcome than the visible
  failure that was actually being reported. Courier now compares the item on
  the mail against the one you queued and refuses to send a mismatch.
- A run that sends **nothing** no longer clears your attachment list. Every
  item is still in your bags in that case, and wiping the list meant rebuilding
  the whole selection to try again.

## [1.1.0]

Adds a mail reader, and fixes a take-engine bug that stopped **Open All** dead
at the first COD mail. `/reload`.

### Fixed
- **Open All stopped partway through the mailbox and never finished.** Any mail
  the engine has to *skip* — COD, GM mail, mail the server refuses, or a
  Delete Read pass over mail that is not already empty-and-read — was stepped
  over without asking the server to do anything. But the engine's clock *is*
  the server's acknowledgement (`MAIL_INBOX_UPDATE`), and no operation means no
  acknowledgement, so the run simply stopped there with everything behind it
  uncollected. Only the Stop button got you out. Every skip now re-arms itself.
- The same bug is why **Take All** never worked: its last step on each mail is
  a skip, so it stalled after the first mail, every time.
- **Delete Read** was affected too — it stalled on the first mail that was not
  already read and empty, which in a normal inbox is almost immediately.
- **The last row of the inbox list drew over the list border and the hint text
  underneath it.** The window was a fixed 440px tall, which left the list 20px
  short of the ten rows it draws, and 1.12 frames do not clip their children.
  The window height is now derived from the list instead of chosen by eye, so
  changing the row count resizes the window rather than overflowing it.
- **You could not send a mail without attaching an item.** Courier refused any
  mail carrying neither an item nor gold, on the theory that such a mail is
  "almost always a mistake". That was simply wrong — writing to someone is the
  most ordinary use of a mailbox there is. A subject or a body is now enough.
  Only a mail with genuinely nothing in it is still refused.
  - The validation rule is asked twice: once when you press Send, and once to
    decide whether the Send button is pressable at all. Only the first was
    fixed to begin with, so the button stayed greyed out and the bug survived
    its own fix. Both now agree, and the suite asserts on the **button**, not
    just on the rule behind it.
- **The little button beside the recipient box did nothing.** Two separate
  faults. It filtered the contact list by whatever was already typed, so
  clicking it with a complete name in the box matched exactly one contact —
  itself — and the "don't suggest an exact match" rule then hid the list again.
  And its icon came from a texture that does not render here, on top of which
  the pfUI skin replaces a button's textures with a flat backdrop, wiping the
  arrow off an icon button entirely. It now lists **every** recent recipient
  regardless of what is typed, keeps its arrow, has a tooltip, and says "no
  saved recipients yet" rather than staying silent when there are none.
- **The window title reported the wrong version.** It was a hand-maintained
  literal in the source, and two releases bumped the `.toc` and left it behind,
  so the title bar kept claiming 1.0.4. It now reads the real version from the
  `.toc` at load, and the test suite parses the `.toc` and fails if the two
  ever disagree again.

### Added
- **You can read your mail.** Left-click a message to open it: sender, subject,
  attachment, money, expiry and the body, with Take and Return available from
  inside. Right-click still takes a mail without opening it, unchanged.
  Auction-house mail also shows its invoice — sale price, house cut, and the
  returned deposit.
- Reading is careful with expiry, because the game is not. The only way to get
  a message body also marks the mail read, and on mail that **still holds
  attachments that drops its expiry from 30 days to 3**. So Courier splits the
  two cases: a mail holding nothing opens and reads immediately, while a mail
  still holding something shows all its detail at once but keeps the body
  behind one explicit click that tells you the cost first. No click in the list
  can ever shorten a mail's life without you choosing it.

### Removed
- **The Take All button.** It emptied every mail but kept it, and it never
  worked properly — see the clock bug above. Open All does what people
  actually wanted and now does it correctly.

## [1.0.5]

Fixes the multi-second freeze when first opening a large mailbox. `/reload`.
This is a **different** bug from the 1.0.4 crash — that one was a stack
overflow past 10 mails, this one is raw work per event — and 1.0.4's fix is
still in place. If you were still seeing a long hang on 1.0.4, this is why.

### Fixed
- **Opening a full mailbox froze the client for seconds.** `MAIL_INBOX_UPDATE`
  does not fire once per visit: on the first open of a session, while the
  client is still resolving attached items it has not cached, it fires *again
  and again* — one storm of events across a handful of frames. Courier did a
  full repaint plus **five separate walks of every mail header** inside every
  one of those events. Measured on a 70-mail inbox that is 352 header reads
  and roughly 1,300 subject-pattern parses **per event**; a 200-event storm
  ran 169,200 header reads before the frame could finish.
- The events now only raise a flag. The work happens **at most once per
  frame**, however many events landed in that frame — the same 200-event
  storm now costs 282 header reads, a single pass. Nothing was made lazier or
  less accurate: the list still repaints on every change, just once instead of
  two hundred times.
- The contact-name harvest for send autocomplete no longer runs on every
  inbox update either — it was one of those five walks. It now runs when you
  open the mailbox and when a take run finishes, which are the only moments
  the set of senders can actually change.
- The minimap's unread-mail count is no longer carried over between mailbox
  visits. A count left from a mailbox you emptied last time could authorise
  hiding a genuinely new unread-mail icon on a later visit.

### Notes
- Caching parsed headers within a single refresh was tried and deliberately
  **not** shipped. The saving was small next to the coalescing above, and a
  stale-header memo is the one thing this addon's correctness cannot afford —
  the take engine re-reads after every action precisely because "I took it,
  therefore it is empty" is false. The reasoning is recorded in
  `core/inbox.lua` for whoever revisits it.
- 1.0.4's re-entrancy guards are untouched; both fixes are needed.

## [1.0.4]

Fixes the reported client freeze/crash with 11 or more mails in the inbox.
`/reload`. Present since 0.1.0, so every prior version is affected.

### Fixed
- **The client froze and crashed once the inbox held more than 10 mails.**
  Courier's list draws 10 rows; at 11+ the scrollbar comes alive, and the 1.12
  FrameXML plumbing turns the refresh into mutual recursion with no exit:
  `FauxScrollFrame_Update` → `SetMinMaxValues`/`SetValue` → slider
  `OnValueChanged` → `SetVerticalScroll` → `OnVerticalScroll` → the update
  function → `FauxScrollFrame_Update` again. The client hangs, then dies on
  stack overflow. At 10 or fewer mails `FauxScrollFrame_Update` takes its
  `Hide()` branch and the slider never fires — which is exactly why the crash
  threshold sat at 11 and why small inboxes never showed it.
- The trigger in practice: scrolling a big inbox, or **Open All** shrinking
  the list under a live scrollbar (every delete clamps the scroll value and
  re-enters the refresh). A freshly opened, unscrolled inbox could still paint
  once, which is why screenshots of full inboxes exist.
- All three scrolling lists — Inbox, Log, Ledger — now carry a reentrancy
  guard that bounces the recursive call. The outer pass reads the clamped
  offset immediately after `FauxScrollFrame_Update`, so the paint stays
  correct, including the scrolled-to-bottom-while-deleting case.

### Changed
- `CLAUDE.md` rule 28 gains the reentrancy requirement: every FauxScrollFrame
  update function must carry this guard.

### Tests
- Harness grows to **377 checks**. The FauxScrollFrame stubs were no-ops —
  the recursion was unreachable by any test, and no test inbox ever held more
  than 5 mails. They are now ported from the 1.12.1 `UIPanelTemplates.lua`/
  `.xml`, including the synchronous re-fire on a live scrollbar. New coverage:
  10 mails leave the scrollbar dormant, 11 scrolled mails terminate (the crash
  case), a 54-mail box scrolled deep, Open All emptying 30 mails under a live
  scrollbar, and the Log and Ledger equivalents.
- Sabotage-checked: removing the guard makes the 11-mail and 54-mail checks
  fail with a genuine Lua stack overflow — the same death the client was
  reported to hit.

## [1.0.3]

Fixes a reported failure to send multiple items: *"the server rejected that
mail; 1 of 2 sent."* `/reload`.

### Fixed
- **A refused mail no longer throws the rest of the batch away.** `MAIL_FAILED`
  aborted the whole run, so one hiccup on the second of twelve mails lost the
  other ten and the attachment list had to be rebuilt. The mail is now put back
  at the head of the queue and retried — safe by construction, because
  `MAIL_FAILED` means that mail did *not* go out, so a retry cannot duplicate
  it. The budget is **per mail** and resets on each success, so a long batch is
  not capped by an earlier hiccup. When a mail is refused past its budget the
  run stops with a message naming which mail failed and how many are still
  attached, and **everything unsent stays on the list** so Send can just be
  pressed again.
- **A plain gold send no longer touches the C.O.D. channel.** Mails after the
  first zeroed *both* money channels, so an ordinary gold send called
  `SetSendMailCOD(0)` on every subsequent mail — poking the outgoing mail into
  C.O.D. mode with a zero amount purely to clear something that was never set.
  Only the channel actually in use is ever written now, which is what
  TurtleMail does and it is the implementation known to work on this client.

### Changed
- Courier now lets the mail system settle briefly between a confirmed send and
  the next one, instead of firing on the very next OnUpdate frame (~16ms after
  the acknowledgement). **This is a mitigation, not a proven root cause** — see
  below — and it costs a few seconds on a twelve-item batch.

### On the root cause, honestly
The underlying reason the server refused the second mail has **not** been
identified. Ruled out by inspection: the Aegis bridge change in 1.0.2 (it does
not touch sending), the subject and body length caps (64 and 500, matching
`MailFrame.xml` exactly), and the call sequence itself — TurtleMail's is
structurally identical, including the one-frame defer.

What is fixed is Courier's *response* to a refusal, which was wrong regardless
of what provokes it. If a batch still stalls, the new message reports which
mail failed; that plus whether gold or C.O.D. was attached would narrow it
further.

### Tests
- Harness grows to **367 checks**, and the send stub is now faithful enough to
  refuse: every `SendMail` returns exactly one of `MAIL_SEND_SUCCESS` /
  `MAIL_FAILED`, and the cursor is modelled properly — picking an item up
  *leaves it in the bag* flagged locked, and taking an attachment back off
  returns it to the slot it came from, which is the path a retry travels.
- The previous stub kept an item in the bag while it was simultaneously on the
  cursor, which is why nothing could exercise a refused send at all.
- Both fixes were sabotage-checked: reverting the retry fails only *"BOTH mails
  were sent despite the refusal"*, and restoring the two-channel zeroing fails
  only the two channel-isolation assertions.

## [1.0.2]

Fixes the Aegis: Exchange integration, which has never once worked. `/reload`.
Nothing changes for standalone users — Courier's own mail handling, ledger and
history are untouched, and were always the record of truth.

### Fixed
- **Every sale pushed to Aegis: Exchange was silently discarded.** Courier
  called Aegis's `RecordExternalTxn` with four positional arguments; it takes
  a single table. Aegis rejects a bad payload by **returning** `false` rather
  than raising, so the `pcall` guarding the call reported success, Courier
  believed the entry was mirrored, and neither addon said a word. Users running
  both saw Courier's own history fill up correctly while Aegis's stayed empty.

  Both sides claimed integration contract v1, so the version check could not
  catch it. Aegis is unchanged — its shape was always the published one.
- **A refusal from Aegis is no longer read as success.** `bridge.Push` checked
  only whether the call *errored*, discarding the `false, reason` Aegis returns
  for a payload it declines. It now reports what Aegis actually said, so the
  next contract drift surfaces instead of vanishing. This is the change that
  matters most — it is what made the bug above invisible for the addon's whole
  life.

### Changed
- **The test double for Aegis is now ported from Aegis's real source**, not
  written from Courier's assumption about it. The old fake took the same wrong
  positional arguments as the caller, so both agreed and the suite passed over
  a dead seam. It now takes a table, validates like the real thing, and returns
  `true` / `false, reason` — a mock that can disagree with a wrong caller.
- **No dedup key is sent with a push**, now stated explicitly and tested.
  Aegis's `MailTxnKey` buckets subject + money + arrival-hour, which is exactly
  the fingerprint `inbox.lua`'s Stage B note rejects: two identical stacks sold
  at the same price in the same hour collide, and a collision silently
  *under*-counts. Courier books on collection, so an emptied mail cannot be
  booked twice and needs no key.

  The known trade-off: auction mail that Aegis already booked on arrival and
  that is still sitting uncollected when Courier is installed gets counted
  twice. That is a one-time, bounded overlap at handover, and it is preferable
  to a permanent undercount — a missing sale is invisible, a doubled one is at
  least conspicuous.

## [1.0.1] - 2026-08-06

Fixes the reported "you have unread mail" flag never clearing. `/reload`.

### Fixed
- **Mail taken by Courier was never marked read.** On 1.12 there is no
  "mark read" call — `GetInboxText(index)` does it as a side effect of
  fetching the body, and Courier never called it. TurtleMail calls it as the
  first step of processing every mail; it was omitted here because that line
  reads like it is only fetching body text. The take engine now calls
  `inbox.MarkRead` before emptying a mail.
- **The minimap icon is now put out explicitly.** It tracks `HasNewMail()`,
  which the client does not re-evaluate merely because the inbox was emptied,
  so in vanilla it can stay lit until the next login. When the mailbox closes
  with nothing unread left, Courier hides it — the same workaround Postal
  uses. It is only ever hidden when the unread count is known to be zero, so a
  genuine notification is never suppressed, and new mail lights it again.
- **Knock-on: "Delete Read" could never find anything.** Same root cause — with
  nothing ever marked read, the button was permanently greyed out. It now
  works after a Take All.

### Behaviour worth knowing
- Only mail Courier is **actively emptying** is marked read. Browsing the
  inbox marks nothing, deliberately: reading a mail that still holds
  attachments drops its expiry to three days, so marking on display would
  quietly shorten the life of mail you meant to keep.
- COD and GM mail are skipped entirely and are not marked read either.

### Changed
- `CLAUDE.md` gains rule 17 covering both halves of this, since it is exactly
  the kind of detail that gets left out twice.

### Tests
- Harness grows to **346 checks**. `GetInboxText` in the stub now models the
  read side effect, which is the whole reason for calling it. Covers: taking
  marks read, browsing does not, COD/GM are untouched, the icon is left alone
  while anything is unread, cleared when nothing is, and Delete Read finding
  work after a Take All.

## [1.0.0] - 2026-08-05 — **restart**

Stage C.3, and the first complete release. Every stage on the roadmap is done:
Courier replaces TurtleMail feature-for-feature per `docs/turtlemail-audit.md`,
and adds the auction ledger TurtleMail never had.

**Adds `ui/skin.lua` to the `.toc`, so a full client restart is required** —
1.12 reads the file list at startup and `/reload` will not pick it up.

### Added
- **Optional pfUI skin.** When pfUI is installed, Courier restyles its window,
  wells, buttons, checkboxes, edit boxes and scrollbars through
  `pfUI:GetEnvironment()` — the same entry point pfUI-addonskinner uses.
- **On by default**, with an option in the Courier tab. With pfUI absent the
  option is greyed out and labelled, rather than hidden, so it is clear the
  feature exists and why it is inactive. The setting stays on, so installing
  pfUI later just works.
- Turning it **on** applies immediately. Turning it **off** needs a `/reload`,
  since pfUI's styling cannot be cleanly undone — Courier says so rather than
  appearing to do nothing.
- `pfui/Aegis_Courier.lua`, a drop-in for pfUI-addonskinner users. It is
  **not** in the `.toc` and is not loaded by Courier.

### Behaviour worth knowing
- pfUI is **never** a dependency. It is not in the `.toc`, every call into it
  is `pcall`-guarded, and the worst a pfUI API change can do is leave you with
  Courier's default look. Tests cover a pfUI that throws on every helper, one
  whose environment cannot be fetched, and one exposing no helpers at all.
- Inbox rows and attachment slots opt out of button styling — they are click
  targets and icon wells, not buttons.
- Sub-tab tinting follows pfUI: `CreateBackdrop` attaches a child frame, and
  the selected-tab colour is applied to whichever backdrop is real, so the
  selected tab still reads as selected.

### Tests
- Harness grows to **328 checks**.
- **The frame mock now models the frame tree and distinguishes methods from
  data.** Two bugs had been hiding in it: unknown keys returned a truthy no-op
  function, so data fields like `frame.backdrop` looked real; and there was no
  parent/child wiring, so anything that walks the frame tree traversed an empty
  list and passed vacuously. Methods are CamelCase and data fields are
  lowercase in this codebase, so the mock now uses the initial capital to tell
  them apart, and `CreateFrame` records children. The skin's tree walk is
  genuinely exercised as a result.

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

[1.0.4]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v1.0.4
[1.0.3]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v1.0.3
[1.0.2]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v1.0.2
[1.0.1]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v1.0.1
[1.0.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v1.0.0
[0.5.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.5.0
[0.4.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.4.0
[0.3.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.3.0
[0.2.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.2.0
[0.1.0]: https://github.com/Torchlite-bit/Aegis_Courier/releases/tag/v0.1.0
