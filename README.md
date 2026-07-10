# BetterTogether



**Website:** [peavers.io](https://peavers.io) | **Addon Backup:** [vault.peavers.io](https://vault.peavers.io) | **Issues:** [GitHub](https://github.com/peavers-warcraft/BetterTogether/issues)

<!-- peavers:custom -->
# BetterTogether

A World of Warcraft addon that gives duo players a live readiness dashboard for their partner — flask, food, repairs, and quests at a glance before every pull — plus a shared scrapbook of everything you've done together.

**Website:** [peavers.io](https://peavers.io) | **Addon Backup:** [vault.peavers.io](https://vault.peavers.io) | **Issues:** [GitHub](https://github.com/peavers-warcraft/BetterTogether/issues)

## Features

- Live partner readiness with a single green/amber/red verdict: repairs, flask, food, weapon oil, augment rune, and bag space
- Rotatable 3D model of your partner with their location, resting state, Mythic+ keystone, and gold
- Shared statistics: bosses downed, dungeons and Mythic+ completed, and time played together
- Achievements scrapbook, browsable by expansion, highlighting the ones you earned on the same day
- Quest comparison showing what you're both on, and what only one of you has picked up
- Browse your partner's bags with full item tooltips
- Partner roster with online status and one-click switching
- Per-category privacy controls — anything unticked never leaves your client
- Combat-safe by design: all checks happen out of combat, with batched addon messages

## Installation

1. Download from [CurseForge](https://www.curseforge.com/wow/addons/bettertogether) — both partners need it installed
2. Ensure [PeaversConsumablesData](https://www.curseforge.com/wow/addons/peaversconsumablesdata) is also installed
3. Enable the addon on the character selection screen

## Usage

1. One of you types `/bt invite <partnerName>` (pairing works over whisper — no party needed)
2. The other clicks **Accept** (or types `/bt accept`)
3. The pairing is saved and reconnects automatically from then on

- `/bt` - Open the panel / settings
- `/bt invite <name>` - Send a pairing request
- `/bt partners` - List everyone you've bonded with
- `/bt switch <name>` - Make a different saved partner active
- `/bt lock` - Lock or unlock the panel's position
- `/bt collapse` / `/bt expand` - Switch between compact and full views
- `/bt stats` - Jump straight to your shared statistics
- `/bt privacy` - Jump straight to privacy controls
- `/bt sync` - Ask your partner for a fresh update

## Configuration

Open settings with `/bt` to customize:

- Panel scale and position lock
- Durability threshold for the readiness verdict
- Which checks are blocking (red) vs. a heads-up (amber)
- Which readiness rows are visible
- Quest broadcast: share your super-tracked quest automatically, or pin one

## Dependencies

- [PeaversConsumablesData](https://www.curseforge.com/wow/addons/peaversconsumablesdata) (required)
<!-- /peavers:custom -->

## Installation

### Recommended: PeaversUpdater

Download and install [PeaversUpdater](https://github.com/peavers-warcraft/PeaversUpdater/releases/latest), the desktop updater for the whole Peavers collection. It installs BetterTogether together with its required dependencies and delivers updates about a week before they reach CurseForge.

### Alternative: CurseForge

1. Download from [CurseForge](https://www.curseforge.com/wow/addons/bettertogether)
2. Ensure [PeaversCommons](https://www.curseforge.com/wow/addons/peaverscommons) is also installed
3. Ensure [PeaversConfig](https://www.curseforge.com/wow/addons/peaversconfig) is also installed
4. Enable the addon on the character selection screen

---

*Part of the [Peavers](https://peavers.io) addon collection · [Report an issue](https://github.com/peavers-warcraft/BetterTogether/issues) · [Support development on Patreon](https://www.patreon.com/Peavers)*
