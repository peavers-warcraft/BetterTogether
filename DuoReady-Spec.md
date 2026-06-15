# DuoReady — Partner Readiness Dashboard
### WoW Addon · Build Specification (handoff-ready)

**Target game version:** World of Warcraft: Midnight, Patch 12.0.x (Interface `120000`)
**Author:** Chris (peavers-warcraft org)
**Contest:** CurseForge WoW Addon Trials — submission deadline **July 5, 2026**
**Document purpose:** Complete spec for a coding agent to implement without architectural guesswork. Where a value must be confirmed in-client, it is flagged **[VERIFY IN-CLIENT]**.

---

## 1. One-line concept

A paired addon for two players who run content together. Each person installs it; the two clients handshake over the addon comm channel and each renders a **readiness dashboard of the *other* person** — repairs, flask, food, weapon enchant, key buffs, durability, bag space, and current quest + step — so you know at a glance, **before the pull**, that your partner is actually prepared and on the right quest.

Built for duo play (e.g. a Holy Paladin + BM Hunter couple), a shape almost no addon serves: too small for raid tooling, too interdependent for solo tooling.

---

## 2. Scope & non-goals

### In scope (v1.0, contest build)
- Two-client pairing over `PARTY` addon channel.
- Each client reads **its own** player state (quests, durability, bags, consumables, buffs) and broadcasts a compact snapshot.
- Each client renders the **partner's** snapshot as a dashboard panel.
- Out-of-combat operation only (by design).
- Manual + automatic "is my partner ready?" readiness summary with a single green/red verdict.

### Explicit non-goals
- **No combat logic.** Nothing read or acted on during combat. This sidesteps Midnight's Secret Values restrictions entirely. (See §9.)
- **No automation of game actions** (no auto-anything; forbidden + pointless here).
- **Not a raid/party-wide tool.** Designed for exactly 2 linked players. (Architecture should not *preclude* N>2 later, but v1 ships for 2.)
- **No collection/decor/housing anything.**

---

## 3. Why this is API-feasible (confirmed facts)

| Capability | Mechanism | Status |
|---|---|---|
| Two addons exchange data across accounts | `C_ChatInfo.SendAddonMessage(prefix, msg, "PARTY")` + `CHAT_MSG_ADDON` + `RegisterAddonMessagePrefix` | **Confirmed working under Midnight 12.0** (live addons use it post-disarmament) |
| Read own quest log + step | `C_QuestLog.GetInfo`, `C_QuestLog.GetQuestObjectives`, `C_QuestLog.GetTitleForQuestID` | Confirmed |
| Read own equipment durability | `GetInventoryItemDurability(slotId)` → current, max | Confirmed |
| Read own bag space | `C_Container.GetContainerNumFreeSlots` / `GetContainerNumSlots` | Confirmed |
| Read buffs (flask/food/enchant) | `C_UnitAuras.GetAuraDataByIndex("player", i)` / weapon via `GetWeaponEnchantInfo()` | Confirmed for **own** player; partner via self-report (see §6) |

**Self-report architecture is the key design choice:** each client only ever reads *its own* player and *sends* the result. No client tries to read protected state about the other player. This makes the whole addon immune to Secret Values, because reading your own out-of-combat player state is unrestricted.

---

## 4. Comm protocol

### 4.1 Prefix
- Registered prefix: `"DuoReady"` (≤16 chars ✓) via `C_ChatInfo.RegisterAddonMessagePrefix("DuoReady")` on load.
- Channel: `"PARTY"` for all normal syncs (both players are partied in the open world).
- **[VERIFY IN-CLIENT]** Confirm `PARTY` delivery works in the open world when not in an instance (expected yes). Fallback: `WHISPER` to partner's name if party delivery is unreliable.

### 4.2 Throttle budget (hard constraint)
- Per-prefix allowance: **max 10 messages, regenerating 1/sec** (returns `Enum.SendAddonMessageResult.AddonMessageThrottle` when exceeded).
- **Design rule:** never send one message per data point. Batch the entire snapshot into **one** message. Send only:
  - on `PLAYER_ENTERING_WORLD` / handshake,
  - on a **debounced change** (state changed + ≥2s since last send),
  - on explicit partner **request** (e.g. partner just logged in and asks for a full snapshot).
- Hard cap: **no more than 1 snapshot every 2 seconds** per client, even if state churns.

### 4.3 Message types (first token = type)
```
HELLO|<version>|<charName>          -- announce presence, request partner HELLO back
SNAP|<version>|<payload>            -- full readiness snapshot (see schema)
REQ                                 -- ask partner to send a fresh SNAP now
BYE                                 -- graceful unpair (logout/leaving party)
```

### 4.4 Snapshot payload schema (`SNAP`)
Serialize as a single delimited string (keep under 255 chars; if it grows, chunk — see §4.5). Use `LibSerialize`+`LibDeflate` if pulling in libs, OR a hand-rolled pipe/caret format for zero deps. Recommended **zero-dep** format:

```
SNAP|1|dur=<int%>|bags=<freeSlots>|flask=<0|1>|food=<0|1>|wpn=<0|1>|
     rune=<0|1>|hp=<0|1 fullHP>|combat=<0|1>|
     qid=<questID>|qstep=<curObjIndex>/<numObj>|qpct=<int%>|qname=<short>
```

Field notes:
- `dur` = lowest durability across equipped slots, as integer percent (the weakest link is what matters).
- `bags` = total free slots across normal bags.
- `flask`/`food`/`wpn`/`rune` = booleans derived by scanning own auras / weapon enchant for known consumable buff spellIDs (maintain a `Consumables.lua` table of current-tier spellIDs; see §7).
- `qid` = tracked/selected quest ID (the one the duo is presumably coordinating on). Default: the **super-tracked** quest via `C_SuperTrack.GetSuperTrackedQuestID()`. Allow user to pin a specific quest to broadcast.
- `qstep` / `qpct` = objective progress from `C_QuestLog.GetQuestObjectives(qid)`.
- `qname` = truncated title (≤ ~40 chars) from `C_QuestLog.GetTitleForQuestID(qid)`.

### 4.5 Chunking (only if needed)
If payload > 240 chars, split into `SNAP|1|i/n|<chunk>` and reassemble on receipt keyed by sender. Prefer to keep snapshots small enough to avoid this in v1.

---

## 5. State model

```
DuoReady.self      = { ...own live readiness, recomputed on relevant events... }
DuoReady.partner   = { ...last decoded SNAP from partner, + lastSeen timestamp... }
DuoReady.linked    = boolean         -- true once HELLO handshake completed
DuoReady.partnerName = string|nil
```

- `partner.lastSeen` drives a **stale** indicator: if no SNAP in >30s, dim the panel and show "waiting for <name>…".
- On `BYE` or party-leave, set `linked=false`, clear partner panel.

---

## 6. Buff reading: direct vs self-report

Two paths; **self-report is the v1 default** because it is restriction-proof and symmetric:

1. **Self-report (default, ship this):** each client scans *its own* auras for flask/food/weapon-enchant/rune and sends booleans. Always works, out of combat, no Secret Values exposure.
2. **[VERIFY IN-CLIENT] Direct read (optional enhancement):** test whether `C_UnitAuras.GetAuraDataByIndex("party1", i)` returns usable (non-secret) data **out of combat**. The 12.0 API exposes `C_Secrets.ShouldUnitAuraIndexBeSecret` etc., implying auras *can* be secret in some contexts. If direct party-member aura reads are clean out of combat, it allows showing partner buffs even before they've updated — but it is NOT required. Keep behind a feature flag; do not block v1 on it.

---

## 7. Files / module layout

```
DuoReady/
  DuoReady.toc
  Core.lua            -- addon namespace, event frame, init, saved vars
  Comm.lua            -- prefix reg, send/receive, throttle queue, (de)serialize
  SelfState.lua       -- reads OWN quest/durability/bags/consumables -> DuoReady.self
  Consumables.lua     -- spellID tables for current-tier flask/food/rune/wpn buffs
  Snapshot.lua        -- build SNAP payload from self; decode incoming SNAP -> partner
  UI/
    Dashboard.lua     -- the partner panel (frames, rows, verdict light)
    Row.lua           -- a single readiness row widget (icon + label + status)
    Settings.lua      -- options panel (pin quest, toggles, position/scale)
  Libs/               -- (optional) LibStub, LibSerialize, LibDeflate, Ace3 if used
  Media/              -- icons, status textures
```

### 7.1 TOC essentials
```
## Interface: 120000
## Title: DuoReady
## Notes: Partner readiness dashboard for duo play.
## Author: <you>
## Version: 1.0.0
## SavedVariables: DuoReadyDB
## IconTexture: Interface\AddOns\DuoReady\Media\icon
```
(Per contest rules: **do not** use an AI-generated project avatar; the in-game `IconTexture` is fine but the CurseForge page avatar must be human-made.)

---

## 8. UI / UX spec (this is 1/3 of the score — design)

### 8.1 The partner panel
A compact, movable, lockable frame showing the **partner's** readiness. Layout top→bottom:

```
┌───────────────────────────────┐
│  ● AMY — READY                │   <- verdict light: green=all good, amber=minor, red=problem
├───────────────────────────────┤
│ 🛡 Repairs      92%      ✓     │
│ ⚗ Flask        active   ✓     │
│ 🍖 Food buff    active   ✓     │
│ 🗡 Weapon oil   missing  ✗     │
│ 🎒 Bag space    14 free  ✓     │
├───────────────────────────────┤
│ 📜 The Dark Below   (2/3)      │
│    step: Cleanse the wards     │
└───────────────────────────────┘
```

### 8.2 Verdict logic
- **Green "READY":** durability ≥ threshold (default 30%), flask + food present, bags > 0.
- **Amber:** minor issue (e.g. weapon oil missing, or quest mismatch) — configurable which checks are "blocking" vs "advisory."
- **Red:** a blocking check fails (no flask, durability < threshold, bags full).
- Thresholds + which checks are blocking live in Settings.

### 8.3 Quest awareness (the standout feature)
- Show partner's pinned/super-tracked quest + objective step.
- **Mismatch highlight:** if YOUR super-tracked quest ≠ partner's, show a subtle "↯ different quest" marker. This is the "is she going the right direction" signal you asked for.
- If partner lacks a quest you have (compare qid), optionally show "✗ doesn't have: <quest>".

### 8.4 Design direction
- Clean, modern, not 2010-era WoW. Subtle background, crisp status icons, restrained color (green/amber/red only for status, neutral otherwise).
- Movable (drag), scalable (slider), lockable. Position saved per character.
- A "demo mode" / test fixture that renders the panel with fake partner data so it looks good in screenshots/video for the **community vote** even when solo. (Important: the July 9–13 vote is won on visuals.)

---

## 9. Midnight restriction compliance (do not violate)

- **Never** read protected combat values (`UnitHealth`, `UnitPower`, auras, cooldowns) on tainted paths during combat. v1 simply does not operate in combat.
- Guard any aura/unit reads with `issecretvalue()` / `canaccesssecrets()` checks before doing arithmetic/concat/compare, to avoid the "tainted by DuoReady" error spam seen in early Midnight addons.
- All cross-player data flows via self-report over addon comms, never via reading the other player's protected state.
- Respect the addon-message throttle (§4.2); exceeding it can disconnect the client.
- **[VERIFY IN-CLIENT]** Confirm `AddOnMessageLockdown` result only triggers in combat-restricted states (expected) and never fires for our out-of-combat sends.

---

## 10. Milestones → July 5

> ~3 weeks. Front-load the two load-bearing unknowns so a dead end surfaces early, not late.

**Milestone 0 — Spike (Days 1–2): de-risk the foundation.**
- Bare addon: register prefix, two accounts party up, send `HELLO`, receive it, print to chat.
- Confirm PARTY delivery in the open world; confirm throttle behavior; confirm `AddOnMessageLockdown` only in combat.
- **Gate:** if comms don't work out of combat → stop, reassess. (They should; this just proves it on your hardware.)

**Milestone 1 — Self state + snapshot (Days 3–5).**
- `SelfState.lua`: read own durability, bags, quest (id/step/pct/name), consumables booleans.
- `Snapshot.lua`: encode/decode SNAP. Round-trip a snapshot between you and Amy, print decoded values.

**Milestone 2 — Dashboard UI (Days 6–10).**
- Partner panel, rows, verdict light, movable/lockable/scalable, saved position.
- Quest row + mismatch marker.
- Demo-mode fixture for screenshots.

**Milestone 3 — Polish + settings (Days 11–15).**
- Settings panel: thresholds, blocking vs advisory checks, pin-quest selector, toggles.
- Stale/waiting state, BYE handling, reconnect on re-party.
- Consumables spellID table filled for current Midnight tier.

**Milestone 4 — Hardening + ship (Days 16–19).**
- Throttle queue stress test (rapid state churn must never exceed budget).
- Secret-value guards verified (no taint spam).
- Fresh-install test on both accounts; write CurseForge page copy; **human-made avatar**; publish + submit form.
- Buffer days 20–21 before July 5.

---

## 11. Open items to VERIFY IN-CLIENT (consolidated)
1. `PARTY` addon messages deliver in open world (non-instance). [expected: yes]
2. `AddOnMessageLockdown` only triggers in combat-restricted states. [expected: yes]
3. Whether `C_UnitAuras` reads on `party1` are clean out of combat (enables optional direct-read mode; **not required**).
4. Current-tier consumable spellIDs (flask/food/rune/weapon) for the Consumables table.

---

## 12. Stretch (post-contest, do NOT build for v1)
- N>2 small-group mode.
- "Ready check for two" button + sound.
- Per-encounter consumable expectations (e.g. flask of the right type).
- Sharing a duo "prep profile" string.
- Optional direct party-aura read mode if §6.2 verifies clean.

---

*End of spec.*
