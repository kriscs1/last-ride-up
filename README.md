# Last Ride Up (Godot 4)

Co-op 2D platformer for phones: an expedition stranded in the ruins gathers enough Sunstone to power a crashed skyship and escape together. Hidden traitors spend Guile to sabotage the way out.

This is **Milestone 3: hidden traitors**, built on Milestone 2's online multiplayer, three maps and vein gathering. One Godot project contains the game client and a headless dedicated server. Both run the same rules code.

## Maps

The host picks a map in the lobby, or **Random** for a different one each round. Every map is 150 × 64 tiles with the same camp and mechanisms, but its own layout, look and centrepiece. Underground, each map is split into **named rooms**. Each room has a theme: its own colours, back-wall pattern (brick, planks, tiles, roots, crystal…), props (bookshelves, mine carts, reeds, chandeliers…), lights, and in some rooms water. `tools/check_map.py` proves each map is fully reachable and has no softlocks.

| Map | Character | Rooms |
|---|---|---|
| **Verdant Reach** | Ruins above, a sunken temple below, built around the two-storey **Great Sanctum** where the Heartstone rests. Arched halls, warm candlelight. | Root Cellar, Old Library, Chapel, Cloister, Greenhouse, Flooded Crypt, Ossuary, Great Sanctum, Shard Mine, Catacombs, Reliquary (secret), Deep Spring |
| **Shard Mines** | A V-shaped mine under a night sky. Two long declines of rooms step down from the west and east edges and meet at the wide **Crystal Heart** cavern at the bottom. The **Main Shaft** lift drops straight from camp to the Heart. Rails, carts and timber supports. | West Adit, Lamp Room, Cart Depot, Pump House, Old Workings, Deep Seam, Foreman's Office, Crystal Heart, Powder Store, Ore Chute, East Adit, Smelter, Flooded Shaft, Collapsed Drift, Lost Cache (secret) |
| **Hollow Marsh** | A misty bog with dead trees on the skyline. Lumpy root chambers and flooded pools, all reached from inside the giant **Hollow Tree**, climbed from its open top to the bottom. The most rooms and the most dead ends. | 20 rooms incl. Reed Bed, Old Boathouse, Heron Roost, Lantern Hollow, Frog Pond, Mushroom Grove, Eel Pool, Smugglers' Den, Glowworm Grotto, Bone Pit (secret), Sunken Shrine, Drowned Chapel, Root Maze, Rootheart, Black Water, Old Well |

![Verdant Reach](docs/map_verdant.png)
![Shard Mines](docs/map_mines.png)
![Hollow Marsh](docs/map_marsh.png)

> **Status:** runs in Godot 4.7.2. All 30 rule tests pass, the project imports with no script errors, and 10 clients have played a match together on one dedicated server. Snapshots are deflate-compressed and stay under one UDP packet even with 10 players (about 1.2 KB, checked by a test).

## Requirements

- Godot **4.7** (standard build, not .NET). It should also open in 4.3 to 4.6.
- For phone builds: Godot export templates, plus the Android SDK and/or Xcode.

## First run

```bash
# 1. Let Godot import the project and build its class cache (once, or open it in the editor)
godot --headless --path . --import

# 2. Rule tests (headless, exit code 0 = pass)
godot --headless --path . --script res://tests/run_tests.gd

# Map tools (Python 3, no Godot needed)
python3 tools/check_map.py          # proves every spot is reachable and nothing strands you, even fully loaded
python3 tools/build_maps.py         # regenerate scripts/sim/maps/*.gd from the designer script
python3 tools/render_map_preview.py # docs/map_<id>.png

# 3. Start a dedicated server (UDP port 24680 by default)
godot --headless --path . -- --server
godot --headless --path . -- --server --port 30000
```

Then run the game (F5 in the editor), type a name and press **Quick play** or **Create private room**. To play several clients on one machine, use **Debug → Customize Run Instances…** in the editor and set it to 3 or 4 instances.

**Phones on your Wi-Fi:** the server prints its LAN address at start-up, for example `192.168.1.20:24680`. Type that into **Server address** on the phone. Each player needs their own device or instance.

## Controls

| | Touch | Keyboard | Controller |
|---|---|---|---|
| Move | Drag anywhere on the left side | A/D or arrows | Left stick |
| Climb ladders | Drag up / down on a ladder | W/S or Up/Down | Left stick |
| Drop through planks | Drag down + Jump | S + Jump | |
| Jump (hold for higher) | Big button | Space / K (W / Up when not on a ladder) | A |
| Interact (Strike, Load, Open, Lift, Repair, Valve, Ring bell) | Labelled button | E / F / Enter | X |
| Sabotage (traitors only) | Violet buttons in the Guile panel | 1 Spikes, 2 Bridge, 3 Lift, 4 Taint, 5 Breach | |
| Quickstep dash | Arrows button | Shift / J | B |
| Map | Map button | M / Tab | Back |
| Menu | Menu button | Esc | Start |

Button size and a left-handed layout are in the in-game menu.

## How a match works

- **Verdant Reach** (the other maps work the same way): seven areas: the Skyship Camp, Verdant Ruins and Crown Spire on the surface; the Hollow Marsh, Sunken Hall, Shard Mine and Sunken Vault below. Ladders, one-way drops, false walls and loops connect them. Three **shortcut doors** open only from their far side, so the first trip is long and later ones are quick.
- **Crystal veins** are the main source of Sunstone. Strike one to crack it, and the Sunstone bursts out onto the floor. A **great vein** only cracks when two explorers strike together. Veins regrow after 50 seconds. Loose shards are a small extra.
- **Surges:** every minute or so a vein surges for 20 seconds. It gives double the Sunstone, cracks in half the strikes, and shows on the map.
- **Camp bounties:** three shared goals on the board, for example "crack 2 veins in the Shard Mine", "crack a great vein together" or "bring the Heartstone home". Each one adds a bonus to the charge.
- **Getting hurt:** spikes knock you back with a short stun and a moment of invulnerability. Falling into a pit glides you back out to your last safe ledge. Either way you spill some Sunstone where you can pick it up again.
- **Map (M or the Map button):** shows the layout, you, the skyship, unopened shortcut levers, surging veins, bounty areas and active sabotage. It does **not** show other explorers.
- Gather Sunstone. You can carry 100, and a fuller sack makes you slower and lower-jumping.
- Load it into the skyship's furnace at camp. The required charge grows with the number of players.
- **The Heartstone (150)** needs two players: one presses Lift and a second joins within 3 seconds. Carriers move slower and drop it if they split up.
- **Repairs are shared.** Everyone holding Interact at a broken bridge or jammed lift adds progress.
- When the charge is full the skyship lifts off. It leaves when everyone is aboard or after 30 seconds. The team wins if at least half got aboard.
- **Modes** (the host picks one in the lobby):
  - **No sabotage:** pure co-op.
  - **Test bot:** a hidden bot spends Guile on spikes, the bridge, the lift, engine breaches and secret vein taints. A tainted vein bursts into fool's stone, which weighs the same but is worth nothing at the furnace. The only clue is a faint violet sheen.
  - **Hidden traitors:** the server secretly makes 1 player a traitor (2 with 7 or more players). Your role is shown at the start and is never sent to anyone else's client. Traitors see each other's names in violet, earn Guile over time and spend it on the same sabotages (keys 1-5 or the Guile panel), with an 8-second lie-low after each one. Taint only works standing at a vein.
- **The meeting bell** stands at camp in Hidden traitors mode. Each player can ring it once per match (not in the first 20 seconds, and with a 25-second cooldown after each meeting). The match freezes for up to 40 seconds while everyone discusses and votes for a suspect or to skip. The player with the most votes is exiled only if they beat "skip" with no tie. Their role is revealed, they drop what they carry, and they stay in the match as a ghost.
- **Winning with traitors:** explorers win by escaping (only explorers count towards the half who must get aboard) or by exiling every traitor. Traitors win if the expedition is stranded. The end screen reveals every role and how many sabotages there were.

## Networking in one paragraph

The server is authoritative. Clients send only inputs (30 packets a second, unreliable, each repeating the last few frames so a lost packet costs nothing). The server steps the rules at 60 Hz and sends snapshots 20 times a second. Pickups, loads, sabotage, timers and wins are reliable events. Your own fox is predicted locally with the same `CFSim.step_movement` the server runs, then reconciled when snapshots arrive. Other players are drawn 100 ms in the past, interpolated between snapshots. If you drop out, your seat is held for 60 seconds and you rejoin the running match. See `docs/decisions/0002-networking.md`.

## Project layout

```text
project.godot            Godot 4.7, GL Compatibility renderer (best for phones), landscape
scenes/main.tscn         entry scene → scripts/main.gd
scripts/sim/             shared rules (no nodes, no network): CF config, CFSim, CFLevel, CFVeins, CFMaps, state classes
scripts/sim/maps/        one file per map (ASCII layout, rooms with themes, props, sky theme)
scripts/net/             Net autoload (all RPCs), CFRoom, CFSlot, CFWire
scripts/client/          CFGameClient (prediction, interpolation), CFWorldView (drawing), CFUI, CFTouchControls, CFMapOverlay
tests/run_tests.gd       headless rule tests
tools/                   lint_gd.py (static checks), build_maps.py / check_map.py / render_map_preview.py (maps)
docs/decisions/          architecture decision records
```

## Exporting

- **Android / iOS:** Project → Export → add a preset. The project is already landscape and uses the GL Compatibility renderer.
- **Dedicated server:** add a Linux preset and set *Export Mode → Export as dedicated server*. Run it with `-- --server`. Host it anywhere that allows inbound UDP.

## Known gaps (next up)

- Art is procedural placeholder in the target palette, with Godot's default font. There is no audio yet.
- Three maps, one character (Pip). Six characters come in Milestone 5. A fourth map, the Crown Spire tower, is planned.
- Evidence and witnesses (who was near a tainted vein or a sabotaged lever) come with deduction in Milestone 4. There is no in-game chat yet, so meetings rely on voice chat.
- Next for virality: an end-of-round replay that shows what the traitors really did, join-by-link with a web build, quick-chat and emotes, then sound and juice.
- There is no matchmaking service yet: Quick play fills public rooms on the one server you connect to.
- Inputs and snapshots use Godot's Variant encoding. Packing them into bytes is a later optimisation.
