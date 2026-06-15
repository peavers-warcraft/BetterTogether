# DuoReady — Partner Readiness Dashboard

A paired WoW addon for two players who run content together. Each person installs
it; the two clients handshake over the addon comm channel and each renders a
**readiness dashboard of the _other_ person** — repairs, flask, food, weapon
enchant, aug rune, durability, bag space, and current quest + step — so you know
at a glance, **before the pull**, that your partner is actually prepared and on
the right quest.

Built for duo play (e.g. a Holy Paladin + BM Hunter couple): too small for raid
tooling, too interdependent for solo tooling.

## How it works

Each client reads only **its own** out-of-combat state and broadcasts a compact
snapshot over the `PARTY` addon channel. No client ever reads protected state
about the other player, so the addon is immune to Midnight's Secret Values
restrictions. It does nothing in combat, by design.

## Usage

1. Both partners install DuoReady.
2. One runs `/dr invite <partnerName>`; the other clicks **Accept** on the popup (or `/dr accept`).
3. You're bonded — the pairing is saved and auto-reconnects every login. Drag the panel to position; `/dr lock` to lock it.

Pairing is over whisper, so you don't need to be in a party. The bond persists until `/dr unpair`.

### Slash commands (`/dr` or `/duoready`)

| Command | Effect |
|---|---|
| `/dr invite <name>` | send a pair request to a character |
| `/dr accept` / `/dr decline` | respond to an incoming pair request |
| `/dr unpair` | clear the saved pairing |
| `/dr` | open the options panel |
| `/dr lock` | lock/unlock the panel position |
| `/dr demo` | toggle demo mode (fake partner data for screenshots) |
| `/dr show` / `/dr hide` | show/hide the panel |
| `/dr reset` | reset panel position |
| `/dr sync` | request a fresh snapshot from your partner |
| `/dr test` | single-client loopback (render your own state as a fake partner) |
| `/dr selftest` | whisper-to-self wire test |
| `/dr debug` | toggle debug logging |

## Options

Thresholds (durability), which checks are **blocking** (red) vs **advisory**
(amber), which rows are visible, panel scale, and a pinned broadcast quest are all
configurable in `/dr`.

## ⚠️ Before release — verify in-client (spec §11)

The code is complete; these need confirming on live Midnight 12.0:

1. **`PARTY` addon messages deliver in the open world** (non-instance). _[expected: yes]_
2. **`AddOnMessageLockdown` only triggers in combat-restricted states.** _[expected: yes]_
3. **Consumable spellIDs** in `Consumables.lua` are placeholders from prior tiers
   and **must be updated** for the current Midnight tier. While a buff is active,
   run `/dump C_UnitAuras.GetAuraDataByIndex("player", i)` to read the live
   `spellId`, then add it to the relevant table.
4. (Optional, not required) Whether `C_UnitAuras` reads on `party1` are clean out
   of combat — would enable an optional direct-read mode.

## CurseForge page copy (draft)

> **DuoReady** shows you your partner's readiness — flask, food, repairs, weapon
> oil, bags, and current quest step — at a glance, before every pull. Built for
> two-player duos. No combat logic, no automation, no taint: each client reads
> only its own state and shares a tiny snapshot. Clean, movable, scalable panel.

> **Note:** the in-game icon is a built-in Blizzard texture. Per contest rules,
> the CurseForge project avatar must be **human-made** (do not use an AI-generated
> avatar). Replace `## IconTexture` in the `.toc` with `Interface\AddOns\DuoReady\Media\icon`
> if you ship a custom in-game icon.
