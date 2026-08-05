# CLAUDE.md — Aegis: Courier

A World of Warcraft addon (folder + `.toc` name: **`Aegis_Courier`**) — a
standalone mailbox companion for **Turtle WoW 1.18.1**, which runs the
**ORIGINAL WoW 1.12 (vanilla) client on Lua 5.0**. It replaces TurtleMail and
optionally feeds matched auction mail into **Aegis: Exchange**.

> This is **NOT** WoW Classic and **NOT** retail. Do **not** use any API newer
> than patch **1.12**. When in doubt, assume the API does not exist.

**Courier is fully standalone.** Aegis: Exchange is an *optional* integration,
never a dependency. Everything Courier does must work with Aegis absent.

Planned work lives in [`ROADMAP.md`](ROADMAP.md). The TurtleMail feature audit
that defines "TurtleMail replacement" concretely lives in
[`docs/turtlemail-audit.md`](docs/turtlemail-audit.md) — read it before
building any mailbox feature so scope isn't re-derived from memory.

---

## HARD RULES — never violate these

These are not style preferences. Breaking any of them produces a runtime error
or silent breakage on the 1.12 / Lua 5.0 client.

Sections "Language", "Events", "Hooking", "SavedVariables" and "Frames &
globals" are carried over **verbatim** from Aegis: Exchange's `CLAUDE.md` — the
client-level constraints are identical and must not drift between the two
repos. The Auction House section there is replaced here by the **Mailbox API**
section, which is Courier's equivalent hazard surface.

### Language (Lua 5.0)

1. **Lua 5.0 only.** **NO** `string.match`, **NO** `string.gmatch`, **NO**
   `:match()`. Use **`string.find`** (with captures) and **`string.gfind`**.
   - `string.gfind` is the 5.0 name for what later Lua calls `string.gmatch`.
2. **NO `#` length operator.** Use **`table.getn(t)`**. **NO `table.setn`.**
3. **NO `%` modulo operator.** Use **`math.mod(a, b)`**.
   - Lua 5.0 also has no integer division — combine `math.floor` with
     `math.mod`.
4. **Varargs use the `arg` table and `arg.n`** — not `...` expansion helpers
   from later versions. (`select()` does not exist.)
5. String library note: `string.gsub`, `string.find`, `string.gfind`,
   `string.format`, `string.sub`, `string.lower`/`upper` are fine. The banned
   ones are strictly the `match`/`gmatch` family.

### Events

6. **Event handlers read the GLOBALS `event`, `arg1`, `arg2`, …** — **NOT**
   `function(self, event, ...)`. On this client the OnEvent script receives no
   arguments; the client sets `this`, `event`, and `arg1..argN` as globals.
   - Central dispatch lives in `core/init.lua`. Register with
     `AegisCourier.RegisterEvent(evt, fn)`; the dispatcher reads the globals
     and forwards them.

### Hooking

7. **NO `hooksecurefunc` and NO secure hooks.** Hook by **saving the original
   function and replacing it**, then call the saved original from your
   replacement. (Secure-hook infrastructure does not exist in 1.12.)
   See `ui.HookMailFrame` in `ui/frame.lua` for the canonical pattern.

### Mailbox API (1.12)

8. **`GetInboxHeaderInfo(index)` returns these values, in order:**
   ```
   packageIcon, stationeryIcon, sender, subject, money, CODAmount,
   daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply, isGM
   ```
   Verified against the 1.12.1 `FrameXML/MailFrame.lua` (`InboxFrame_Update`,
   `OpenMail_Update`) and against TurtleMail's usage. Notes:
   - **`daysLeft` is a FLOAT in DAYS**, not seconds and not an integer.
     FrameXML branches on `daysLeft >= 1` and renders
     `SecondsToTime(floor(daysLeft * 24 * 60 * 60))` below that.
   - **`sender` may be `nil`** (FrameXML substitutes `UNKNOWN`). Handle nil.
   - `hasItem` is an item *count* in some server builds and a boolean-ish
     value in others — test truthiness only, never `== true`.
9. **Inbox indices are ABSOLUTE, `1..GetInboxNumItems()`.** The 7-per-page
   layout is a FrameXML *display* convention (`InboxFrame.pageNum`), not a
   limit on what the client can read. Never re-derive an index by page maths
   when iterating the whole inbox — walk `1..GetInboxNumItems()` directly.
10. **There is NO `GetInboxItemLink` on 1.12.** `GetInboxItem(index)` returns
    `name, itemTexture, count, quality, canUse` — a **name and texture, no
    link and no itemID**. Any item identity must be resolved from the NAME.
    Do not write code that assumes a link is obtainable from the inbox.
11. **Hiding `MailFrame` ENDS the mail session.** `MailFrame`'s XML `<OnHide>`
    runs **`CloseMail()`**, so **any** `MailFrame:Hide()` /
    `HideUIPanel(MailFrame)` closes the server session, after which
    `TakeInboxItem` / `TakeInboxMoney` / `DeleteInboxItem` silently do nothing.
    Our standalone window replaces the Blizzard mailbox, so it must hide
    `MailFrame` **without** letting that `<OnHide>` body run: save-and-replace
    its `OnHide`, and while *we* are the one hiding it, skip the default body
    so the session survives. See `ui.HideBlizzardMail` / `ui.HookMailFrame`.
    - The full 1.12 `<OnHide>` body is `CloseMail()`,
      `HideUIPanel(OpenMailFrame)`, `StationeryPopupFrame:Hide()`, three
      `SetText("")` calls on the send-mail edit boxes, and a sound. Suppressing
      it means **we** own resetting the send form.
12. **A SECOND close path lives in `MailFrame_OnEvent`'s `MAIL_SHOW` branch**
    (verbatim from the 1.12.1 FrameXML):
    ```
    ShowUIPanel(MailFrame);
    if ( not MailFrame:IsVisible() ) then
        CloseMail();
        return;
    end
    ```
    So hiding the Blizzard mailbox **synchronously from its own `OnShow`** also
    kills the session. The takeover hide must be **deferred one OnUpdate
    tick** (see `AegisCourierHider` in `ui/frame.lua`). Hiding from our own
    `MAIL_SHOW` handler is safe — it runs after this guard.
    - This is the exact same trap as `AuctionFrame_Show()` in Aegis: Exchange.
      If it is ever "fixed" by making the hide synchronous, the mailbox will
      appear to work and every take/delete will silently no-op.
13. **`CheckInbox()` is throttled server-side.** The client's own `MAIL_SHOW`
    path calls it once. Do not poll it on a tight timer; TurtleMail waits ~200
    OnUpdate ticks between refreshes and that is the pacing to match.

### Mail mutation — the take engine

14. **Never delete a mail that still holds money or an item.** `DeleteInboxItem`
    destroys attachments with no confirmation and no undo. `TakeInboxItem` can
    silently fail (full bag, unique-item cap), so "I called take, therefore it
    is empty" is false. Re-read the header and delete only when `money == 0`
    **and** `hasItem` is false. TurtleMail takes-then-deletes in one step and
    relies on `UI_ERROR_MESSAGE` to catch the failure; that is a race we do not
    reproduce.
15. **Deleting SHIFTS every later mail down one index.** After a successful
    delete, do **not** advance — the next mail slides into the index you are
    already on. Taking money or an item shifts nothing, so a mode that keeps
    the mail must advance itself. Getting this backwards silently skips every
    other mail.
16. **A progress guard must measure CHANGE, not attempts.** Because the delete
    path deliberately does not advance, a raw per-index action counter climbs
    straight through healthy mail and eventually skips a live one. Compare a
    signature of what is at the index (`index|subject|money|hasItem`) and reset
    the counter whenever it moves. See `take.Step`.
17. **Ledger entries are finalized on COLLECTION, never on arrival**, and the
    check fails **closed**: credit money only when it has verifiably left the
    mail. This also *is* the dedupe — an emptied mail has nothing left to book,
    so Courier needs no mail fingerprint. Do not add one; see
    `docs/turtlemail-audit.md`, "Note on mail identity".
18. **Only `sold` mail books income.** `Outbid on %s` mail carries money too —
    the player's own returned bid — and booking it as a sale inflates every
    total the addon reports. `won` / `expired` / `cancelled` carry no price at
    all.
19. **COD and GM mail are never taken automatically**, in any mode, and this is
    not a user setting. Paying a COD by accident is unrecoverable.

### Sending mail (1.12)

20. **Vanilla mail carries exactly ONE attachment.** There is a single slot and
    a single `GetSendMailItem()`. "Mail 12 items at once" is therefore **12
    separate mails**, sent back to back and clocked by `MAIL_SEND_SUCCESS` —
    not a bigger slot. Postage is charged **per mail**, so any cost preview
    must multiply; the stock UI never shows this because it cannot send a
    batch.
21. **There is NO `GetCursorInfo()` on 1.12.** `CursorHasItem()` tells you only
    *that* something is held, never *what*. The only way to identify a dragged
    item is to remember where it came from: save-and-replace
    `PickupContainerItem` / `SplitContainerItem` and record the bag+slot. See
    `send.InstallHooks`.
22. **Verify the attach landed before calling `SendMail`.** `GetSendMailItem()`
    must be non-nil after `ClickSendMailItemButton()`. If the stack moved, sold
    or is soulbound, the attach silently no-ops and `SendMail` posts an **empty
    mail** while the item stays in the bag.
23. **The send API is C, not FrameXML**, so it works with `MailFrame` hidden —
    which is the state the takeover keeps it in. `SendMail`,
    `ClickSendMailItemButton`, `GetSendMailItem`, `SetSendMailMoney`,
    `SetSendMailCOD` and `GetSendMailPrice` are engine-level; only wrappers
    like `SendMailFrame_SendMail` live in Lua. Do **not** call the wrappers —
    they read the Blizzard edit boxes, which are not ours.
    - But note the hidden `MailFrame` **still receives events**, so
      `MAIL_SEND_SUCCESS` still runs Blizzard's `SendMailFrame_Reset()`, which
      calls `SetFocus()` on *its* recipient box. Take the keyboard back
      afterwards or the user's next keystroke vanishes into an invisible frame.
24. **Money rides the FIRST mail of a batch only.** Attaching gold to every
    mail of a 10-item send would send the gold ten times. COD is a charge to
    the recipient rather than a transfer, so it may legitimately repeat — but
    only when the user asked for that.

### SavedVariables

25. **SavedVariables are `nil` until `ADDON_LOADED` fires for
    `"Aegis_Courier"`.** Do all DB setup from the ADDON_LOADED path (queue via
    `AegisCourier.OnLoad(fn)`), never at file scope.
    - `CourierDB` — account-wide (declared `## SavedVariables`).
    - `CourierCharDB` — per-character (`## SavedVariablesPerCharacter`).

### Frames & globals

26. Use **`getglobal()` / `setglobal()`** for dynamic frame names (e.g.
    building `"MailItem" .. n .. "Button"`).
27. Build frames with **`CreateFrame`** using **vanilla templates only**, e.g.
    `UIPanelButtonTemplate`, `FauxScrollFrameTemplate`, `GameTooltipTemplate`.
    - **`FauxScrollFrame_OnVerticalScroll(itemHeight, updateFn)` — 2 args on
      1.12.** The frame and scroll offset are the implicit globals `this` /
      `arg1`. The offset-first form belongs to later clients; using it here
      passes a number as the update function and FrameXML crashes with
      "attempt to call local 'updateFunction' (a number value)".

---

## Aegis: Exchange integration — the whole contract

Courier's integration with Aegis: Exchange is **one function call in one
direction**. These rules are as hard as the client rules above, because
violating them couples two repos that are meant to ship independently.

1. **Detection is a guard, never a dependency.**
   ```lua
   if AegisExchange and AegisExchange.RecordExternalTxn then ... end
   ```
   Courier must load, run and be fully useful with `AegisExchange == nil`.
   There is **no** `## Dependencies` / `## OptionalDeps` line for it in the
   `.toc`, deliberately — see `core/bridge.lua`.
2. **NEVER read or write `AegisExchangeDB` / `AegisExchangeCharDB`.** Not for
   dedupe, not for a "quick check", not read-only. The SavedVariables shape on
   that side is free to change; the function signature is the only promise.
3. **Data flows Courier → Aegis only.** Courier never reads Aegis's ledger,
   price data, or settings back. Anything Courier needs, Courier stores.
4. **Courier's own ledger is always maintained**, whether or not Aegis is
   installed. The push is a mirror, never a substitute — a user who uninstalls
   Aegis must keep their full Courier history.
5. **The push is deduped on Courier's side before it is sent.** Aegis dedupes
   its own scanner's entries with its own keys, which Courier cannot see (rule
   2), so a double-push would double-count.
6. **As of this writing Aegis has NOT yet shipped `RecordExternalTxn`** — it is
   Phase 0.2 on Aegis's own roadmap. The guard is therefore false in practice
   today, and the bridge is dormant. That is expected and must stay harmless:
   never warn, error, or degrade a standalone user because the seam is absent.
7. **Aegis stands down when Courier is present** (Aegis Phase 0.2): its
   built-in `ScanMailSales` skips installing its mail hook once it detects
   Courier, making Courier the sole owner of mail scanning. Courier does not
   need to do anything to cause this, and must **not** try to disable Aegis's
   scanner itself — no reaching into the other addon.

---

## Turtle WoW specifics

Turtle exposes a global **`TURTLE_WOW_VERSION`** — use it to detect Turtle
(see `AegisCourier.isTurtle`).

- **5% faction consignment cut** on auction sales. A sale mail's attached money
  is the **net** already; the gross is `net / 0.95`. Log gross, cut and net.
- **Cross-faction AH** — a single shared economy, so auction mail senders are
  not faction-partitioned. Match the sender against the known auction-house
  name set rather than assuming a faction.
- **Auction durations are ×3 vanilla** — max **72h**. Mail from an auction
  house expires on the normal 30-day mail timer regardless.

---

## Project layout

```
Aegis_Courier/
  Aegis_Courier.toc      -- Interface 11200; declares SavedVariables + load order
  core/init.lua          -- namespace (AegisCourier) + event dispatcher + OnLoad queue
  core/util.lua          -- Lua 5.0 safe helpers (money fmt, strings, time, tables)
  core/db.lua            -- SavedVariables: settings, ledger, dedupe keys, mail log
  core/bridge.lua        -- the Aegis: Exchange seam; dormant when Aegis is absent
  core/inbox.lua         -- inbox reads (A.inbox) + the take engine (A.take)
  core/send.lua          -- outgoing mail: attachments + the batch send engine
  ui/frame.lua           -- standalone Courier window + mailbox takeover
  tests/harness.lua      -- off-client test harness; stubs the 1.12 API
  docs/turtlemail-audit.md -- feature audit that defines the replacement scope
  CLAUDE.md              -- this file
  ROADMAP.md             -- staged plan; check before starting a large feature
```

Load order is fixed by the `.toc`: `init` → `util` → `db` → `bridge` →
`inbox` → `send` → `frame`. `init.lua` must load first (it creates the namespace and
dispatcher); `util` second (every other module takes a file-scope
`local util = A.util`).

**Adding a `.lua` file means editing the `.toc` — and that needs a FULL client
restart, not `/reload`.** 1.12 reads the file list at startup. The module set
above is deliberately laid down complete at Stage A, including files that are
still thin, so later stages don't force users through a restart. Mark any
release that does add a file **restart** in `CHANGELOG.md`.

The repository root **is** the addon folder: clone/copy it into
`Interface/AddOns/Aegis_Courier` so the folder name matches the `.toc`.

---

## Reference addons

Read their patterns for how vanilla mailbox automation is done in practice —
**imitate the approach, do not copy code blindly**:

- **TurtleMail** — https://github.com/sica42/TurtleMail (the addon Courier
  replaces; audited in `docs/turtlemail-audit.md`)
- **Postal (vanilla forks)** — the other common open-all implementation
- **Aegis: Exchange** — https://github.com/Torchlite-bit/Aegis_Exchange (sibling
  repo; the AH takeover in its `ui/frame.lua` is the model for our mail
  takeover, and its `core/db.lua` ledger is the shape our push must match)

---

## Quick self-check before committing Lua

- [ ] No `string.match` / `string.gmatch` / `:match()` — used `string.find` /
      `string.gfind`.
- [ ] No `#` — used `table.getn`. No `table.setn`.
- [ ] No `%` operator — used `math.mod`.
- [ ] Event handlers read `event` / `arg1…` globals (not `self, event, ...`).
- [ ] No `hooksecurefunc` / secure hooks — saved original + replaced.
- [ ] Mail reads match the 13-value `GetInboxHeaderInfo` signature; `daysLeft`
      treated as fractional DAYS; no `GetInboxItemLink` assumed.
- [ ] Nothing hides `MailFrame` without the `keepSessionOpen` suppression, and
      no takeover hide is synchronous with `MailFrame`'s `OnShow`.
- [ ] No `DeleteInboxItem` on a mail that still has money or an item; no
      advance after a delete; only `sold` mail books income; COD/GM skipped.
- [ ] Batch sends verify `GetSendMailItem()` before `SendMail`; postage
      multiplied per mail; gold only on the first mail.
- [ ] `lua5.1 tests/harness.lua` passes.
- [ ] DB touched only after `ADDON_LOADED` for `"Aegis_Courier"`.
- [ ] No read or write of `AegisExchangeDB`; integration goes through
      `core/bridge.lua` only.
