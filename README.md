# Aegis: Courier (v0.2.0)

A standalone mailbox companion for **Turtle WoW** (WoW 1.12 vanilla client) —
a TurtleMail replacement that also understands your auction mail, with
**optional** integration into [Aegis: Exchange](https://github.com/Torchlite-bit/Aegis_Exchange).

> **Stage B pre-release.** The window, the mailbox takeover, the mail actions
> and the auction ledger are all in and tested. Sending mail is Stage C — see
> [Status](#status).

---

## What it is

Courier **replaces** the Blizzard mailbox window rather than decorating it.
Walk up to a mailbox and Courier's window opens in its place, with the whole
inbox in one scrolling list instead of seven rows a page.

It is **fully standalone**. Aegis: Exchange is not required, not a dependency,
and not checked for at load. If you only want a better mailbox, that is all you
need to install.

## Why it exists

TurtleMail automates the mailbox well, but it never does the money maths: it
will tell you a mail came from the auction house and stop there. Courier is
built around the part that's missing — for every completed sale, the **gross
price, the 5% consignment cut, and what actually landed in your bags** — kept
in a real ledger rather than a scrollback you lose on relog.

## Install

Clone or copy this repository into `Interface/AddOns/Aegis_Courier` — the
folder name must match the `.toc`.

```
Interface/AddOns/Aegis_Courier/
    Aegis_Courier.toc
    core/
    ui/
```

## Mailbox actions

| Action | What it does |
|---|---|
| **Open All** | take gold and items, then delete the emptied mail |
| **Take All** | take gold and items, **keep** the mail |
| **Delete Read** | delete read mail that is already empty — never anything holding gold or an item |
| **right-click a mail** | take that one mail |

COD and GM mail are **always** skipped, in every mode and by right-click. That
is not a setting: paying a COD by accident cannot be undone.

Everything runs one mail at a time, clocked by the server's own inbox refresh,
and stops by itself if your bags fill up. A mail is never deleted while it
still holds gold or an item, even if the take failed.

## The ledger

Every completed auction sale you collect is booked with its **gross price, the
5% consignment cut, and the net** that reached you. The entry is written when
the gold actually arrives — not when the mail shows up — so nothing is counted
that you have not received.

Only `Auction successful` mail books income. `Outbid on …` mail carries gold
too, but that is your own returned bid, so it is collected and deliberately
**not** counted as a sale.

## Usage

| Command | What it does |
|---|---|
| `/courier` | toggle the window (`/acr` also works) |
| `/courier status` | integration state and ledger summary |
| `/courier blizzard` | hand this mailbox visit back to the stock window |
| `/courier help` | the above |

The window also carries a **Blizzard UI** button, and the stock mail frame
gets a **Courier** button, so you can swap either way at any time without
closing the mailbox. Turning the takeover off entirely lives in the **Courier**
tab.

## Aegis: Exchange integration

If Aegis: Exchange is installed **and** exposes the integration surface,
Courier pushes each matched sale into Aegis's ledger so its History tab and
price tooltips see mail Courier collected.

The whole contract is one function call in one direction:

```lua
if AegisExchange and AegisExchange.RecordExternalTxn then ... end
```

- Courier **never** reads or writes `AegisExchangeDB`.
- Data flows **Courier → Aegis only**.
- Courier's own ledger is maintained either way, so uninstalling Aegis never
  costs you history.

**Today this seam is dormant**: `RecordExternalTxn` is Phase 0.2 on Aegis's
roadmap and has not shipped yet. Courier detects that and stays quiet — there
is nothing to configure and nothing is broken. The **Courier** tab always shows
the current state.

## Status

| Stage | Scope | State |
|---|---|---|
| **A** | Own window, mailbox takeover, inbox list, ledger/settings tabs, Aegis seam | **done** |
| **B** | Open-all / take-all / delete-read, right-click take; auction matching; sale/cut/net ledger writes on collection | **done** |
| **C** | Send-mail (multi-attach, autocomplete, COD modes), mail log, pfUI skin | next |

What Courier does **not** do yet: sending mail. The send tab is still the stock
Blizzard one — use the **Blizzard UI** button when you need it.

## Compatibility

- **Client:** WoW **1.12** vanilla (Turtle WoW 1.18.1). Not Classic, not retail.
- **Run it instead of TurtleMail**, not alongside — both take over the mailbox
  and will fight over it.
- Running **Aegis: Exchange** alongside is supported and is the intended setup.

## Development

The client constraints (Lua 5.0, 1.12 API only) and the two mailbox behaviours
that fail *silently* when got wrong are documented in
[`CLAUDE.md`](CLAUDE.md) — read it before changing `ui/frame.lua`.

The scope of "TurtleMail replacement" is pinned to a source audit in
[`docs/turtlemail-audit.md`](docs/turtlemail-audit.md).

There is an off-client test harness that stubs the 1.12 API, so the load path,
the subject parsing, the money maths, the takeover and the whole take engine
run without the game:

```sh
lua5.1 tests/harness.lua      # 154 checks
```

Among other things it asserts that hiding the Blizzard mail frame does **not**
end the mail session and that the takeover hide is never synchronous — the two
mistakes that leave a mailbox looking fine while it silently refuses to hand
over mail — and that the take engine never deletes a mail holding an item,
never books a sale the server refused, and never counts an outbid refund as
income.

## Credits

- **TurtleMail** ([sica42](https://github.com/sica42/TurtleMail), shirsig,
  Otari98) — the addon Courier replaces. Its event-driven open-all design and
  its use of the client's own localized `AUCTION_*_MAIL_SUBJECT` globals are
  both better than the obvious approach, and Courier follows them.

## License

MIT — see [LICENSE](LICENSE).
