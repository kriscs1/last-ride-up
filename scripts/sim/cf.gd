class_name CF
## Balance and rules config. The server's copy is the truth; clients use the same values to predict.
## Tune here, never in client-only code.

const T := 32
const GW := 150   # every map is GW x GH (checked by tests and tools/check_map.py)
const GH := 64
const SURFACE := 22   # first rock row of the surface; caves are below

const MATCH_TIME := 300.0
const CAPACITY := 100
const MAX_PLAYERS := 10
const TICK_RATE := 60
const DT := 1.0 / 60.0

# Movement
const SPEED := 300.0
const ACCEL_GROUND := 2600.0
const ACCEL_AIR := 1700.0
const DECEL_GROUND := 3000.0
const GRAVITY := 2100.0
const JUMP_V := 770.0
const COYOTE := 0.09
const JUMP_BUFFER := 0.12
const MAX_FALL := 900.0
const LOW_JUMP_GRAV := 2.3

## Weight tiers: [up_to_fraction, label, accel, speed, jump]
const WEIGHT := [
	[0.25, "Light", 1.0, 1.0, 1.0],
	[0.5, "Loaded", 0.8, 1.0, 1.0],
	[0.75, "Heavy", 0.75, 0.88, 1.0],
	[1.01, "Overloaded", 0.7, 0.8, 0.88],
]

# Two players carrying the Heartstone move slower and jump lower
const COOP_SPEED := 0.65
const COOP_JUMP := 0.85
const COOP_MAX_APART := 170.0
const COOP_JOIN_WINDOW := 3.0

const DASH_SPEED := 640.0
const DASH_TIME := 0.16
const DASH_COOLDOWN := 3.0

const HAZARD_LOSS := 0.3
# Getting hurt: spikes knock you back; pits lift you out to your last safe ledge (no teleport)
const KNOCK_VX := 260.0
const KNOCK_VY := 560.0
const STUN_TIME := 0.35
const INVULN_TIME := 1.2
const RECOVER_TIME := 0.8
const RECOVER_ARC := 48.0
# Ladders
const CLIMB_SPEED := 170.0
const CLIMB_SIDE := 110.0

const VALUES := {"coin": 5, "bag": 15, "chest": 40, "relic": 60, "cache": 50, "idol": 150}

# Crystal veins: strike to crack; great veins need two explorers striking together
const VEIN_HP := 3
const GREAT_VEIN_HP := 6
const VEIN_YIELD := [5, 5, 5, 5, 5]                  # shards burst out
const GREAT_VEIN_YIELD := [15, 15, 15, 5, 5, 5, 5, 5, 5]   # clusters and shards (80)
const TOGETHER_WINDOW := 0.8     # seconds between two explorers' strikes on a great vein
const STRIKE_COOLDOWN := 0.3
const VEIN_REGROW := 50.0
# Veins regrow, so a match yields more than one crack per vein. The charge target counts each
# vein's yield this many times. A starting guess: tune it from playtests.
const VEIN_ROUNDS := 2.0
const SURGE_FIRST := 40.0
const SURGE_EVERY_MIN := 50.0
const SURGE_EVERY_MAX := 70.0
const SURGE_TIME := 20.0
const BOUNTY_SLOTS := 3

const DEPART_WINDOW := 30.0
const BOARD_SHARE := 0.5

# Traitor resource (see the plan doc). The Sabotage Director test bot uses these until Milestone 3.
const GUILE_START := 25.0
const GUILE_MAX := 100.0
const GUILE_REGEN := 0.5
const GUILE_LOCKOUT := 8.0
const SAB := {
	"spikes": {"cost": 15.0, "warn": 1.0, "dur": 20.0, "cd": 25.0},
	"bridge": {"cost": 25.0, "warn": 1.2, "cd": 40.0, "repair": 2.5},
	"lift": {"cost": 20.0, "cd": 35.0, "repair": 2.0},
	"taint": {"cost": 20.0, "cd": 30.0},   # secretly turns a vein's yield into worthless fool's stone
	"breach": {"cost": 60.0, "dur": 45.0, "cd": 90.0, "min_t": 45.0, "loss": 0.25},
}
const DIRECTOR_FIRST_AT := 25.0
const DIRECTOR_THINK := 3.0
const DIRECTOR_CHANCE := 0.55

# Hidden traitors and meetings (Milestone 3)
const MODES := ["none", "bot", "traitors"]   # lobby choice: no sabotage, the test bot, or real hidden traitors
const MEETING_TIME := 40.0        # seconds to discuss and vote; ends early once everyone has voted
const MEETING_FIRST_AT := 20.0    # the bell can't be rung in the opening seconds
const MEETING_COOLDOWN := 25.0    # after a meeting ends, before the bell works again
const MEETINGS_EACH := 1          # how many times each player may ring the bell per match
const BELL_RANGE := 34.0


static func traitor_count(players: int) -> int:
	return 2 if players >= 7 else 1

# Networking
const SNAPSHOT_EVERY := 3          # ticks → 20 snapshots a second
const INPUT_BATCH := 2             # frames per input packet → 30 packets a second
const INPUT_REDUNDANCY := 4        # each packet repeats the last few frames (inputs go unreliable)
const MAX_QUEUED_INPUTS := 8
const RECONNECT_GRACE := 60.0
const INTERP_DELAY := 0.1
const DEFAULT_PORT := 24680

enum Tile { E, SOLID, PLANK, SPIKE, BRIDGE, TRAP, FAKE, LADDER, DOOR1, DOOR2, DOOR3 }

const PLAYER_COLORS := ["#2f8f86", "#d9483b", "#3f6ed8", "#e0a21a", "#8a4fd6", "#2fae55", "#e0559a", "#1aa3c9", "#b5651d", "#6b7280"]
## Each colour comes with its own animal. Colours are unique in a room, so animals are too.
const ANIMALS := ["fox", "rabbit", "frog", "bear", "cat", "panda", "raccoon", "owl", "mouse", "pig"]


static func animal_of(color: Color) -> String:
	var html := color.to_html(false)
	for i in PLAYER_COLORS.size():
		if Color(PLAYER_COLORS[i]).to_html(false) == html:
			return ANIMALS[i]
	return "fox"


static func target_share(players: int) -> float:
	return minf(0.85, 0.55 + 0.05 * maxi(0, players - 1))


static func weight_of(frac: float) -> Array:
	for w in WEIGHT:
		if frac < w[0]:
			return w
	return WEIGHT[3]
