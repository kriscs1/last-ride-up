#!/usr/bin/env python3
"""Builds every Last Ride Up map and writes scripts/sim/maps/cf_map_<id>.gd.

Each map is a set of named, themed ROOMS (compartments) joined by doorways, ladders, hatches,
hidden passages and a lift, around one signature space:
  Verdant Reach  - a sunken temple under the ruins, built around the two-storey Great Sanctum
  Shard Mines    - a working mine of square-cut rooms around the Crystal Heart cavern
  Hollow Marsh   - lumpy root chambers and flooded pools around the Hollow Tree, climbed from inside

The ASCII is what the game loads; tools/check_map.py proves every map is fully reachable.

Legend
  #  rock        .  air        =  plank (one-way)    ^  spikes      H  ladder      B  rope bridge
  t  trap plate  F  false wall 1 2 3  shortcut doors / hatches     p q r  levers for doors 1 2 3
  Y  bridge repair lever   G  lift gear
  S  spawn   V  skyship furnace (loading point)   N  ledger board   E  boarding deck
  v  valve   k  checkpoint
  X  crystal vein   W  great vein (two explorers strike together)
  o  Sunstone shard spot   O  cluster spot   C  supply crate   R  Sunstone   K  hidden cache   I  Heartstone
  M m  moving slab top-left at start / end      U u  lift top-left at top / bottom
Every map is 150 x 64 with the surface rock starting at row 22 and the same camp layout.

Each room also gets a theme kit: rock and wall colours, a back-wall pattern and props
(DECOR: [kind, x, y, extra]) that the client draws. Props are scenery only.
"""
import pathlib, random

W, H = 150, 64
SURF = 22
OUT = pathlib.Path(__file__).resolve().parent.parent / 'scripts/sim/maps'

# ------------------------------------------------------------------ theme kits
# floor / hang / wall props; pattern = back-wall style; water = the room is flooded
KITS = {
    # Verdant Reach: temple
    'cellar':    dict(rock='#3d2b22', back='#2b2019', pattern='plank',  floor=['barrel', 'crate', 'barrel'], hang=['roots', 'lantern'], wall=[]),
    'library':   dict(rock='#3a2c26', back='#33241d', pattern='brick',  floor=['bookshelf', 'candles', 'bookshelf', 'desk'], hang=['chandelier'], wall=['banner']),
    'chapel':    dict(rock='#3a3430', back='#2e2b33', pattern='tile',   floor=['pillar', 'candles', 'pillar', 'urn'], hang=['chandelier'], wall=['window', 'banner']),
    'cloister':  dict(rock='#3a3430', back='#2c3029', pattern='brick',  floor=['pillar', 'planter'], hang=['vine'], wall=['window']),
    'greenhouse':dict(rock='#34392c', back='#23332a', pattern='glass',  floor=['planter', 'planter', 'mushroom'], hang=['vine', 'vine'], wall=['window']),
    'crypt':     dict(rock='#2c3326', back='#1d2620', pattern='brick',  floor=['urn', 'bones'], hang=['chain'], wall=['torch'], water=True),
    'ossuary':   dict(rock='#36302a', back='#2a2420', pattern='skulls', floor=['bones', 'urn', 'candles'], hang=['chain'], wall=['torch']),
    'sanctum':   dict(rock='#3a3430', back='#2b2a36', pattern='tile',   floor=['statue', 'brazier', 'pillar'], hang=['chandelier'], wall=['banner', 'torch']),
    'shardmine': dict(rock='#2a2f3a', back='#1a1f2b', pattern='crystal',floor=['crystal', 'cart', 'beam'], hang=['lantern'], wall=['pickaxe']),
    'catacomb':  dict(rock='#33283a', back='#231c28', pattern='skulls', floor=['bones', 'candles', 'urn'], hang=['chain'], wall=['torch']),
    'reliquary': dict(rock='#3a3020', back='#3a2e18', pattern='gold',   floor=['urn', 'candles'], hang=[], wall=[]),
    'spring':    dict(rock='#24333a', back='#16252b', pattern='moss',   floor=['mushroom', 'reeds', 'crystal'], hang=['glowworm', 'roots'], wall=[], water=True),
    # Shard Mines: works
    'lamproom':  dict(rock='#3a3438', back='#33281f', pattern='plank',  floor=['desk', 'crate', 'barrel'], hang=['lantern', 'lantern'], wall=['pickaxe']),
    'depot':     dict(rock='#3a3438', back='#2a2622', pattern='plank',  floor=['cart', 'crate', 'cart', 'barrel'], hang=['lantern'], wall=[], rails=True),
    'office':    dict(rock='#3a3438', back='#3a2a22', pattern='plank',  floor=['desk', 'bookshelf', 'crate'], hang=['lantern'], wall=['banner', 'pipe']),
    'powder':    dict(rock='#3e3030', back='#3a2020', pattern='brick',  floor=['tnt', 'barrel', 'tnt', 'crate'], hang=['lantern'], wall=[]),
    'orechute':  dict(rock='#3a3438', back='#262a30', pattern='rock',   floor=['cart', 'beam'], hang=['chain'], wall=['pipe'], rails=True),
    'grotto':    dict(rock='#24303a', back='#142430', pattern='crystal',floor=['crystal', 'crystal', 'mushroom'], hang=['glowworm'], wall=[]),
    'pumphouse': dict(rock='#30343a', back='#22282e', pattern='brick',  floor=['barrel', 'crate'], hang=['chain'], wall=['pipe', 'pipe']),
    'smelter':   dict(rock='#3a2e28', back='#3a2216', pattern='brick',  floor=['brazier', 'cart', 'brazier'], hang=['chain'], wall=['pipe']),
    'floodshaft':dict(rock='#2a3036', back='#1a2430', pattern='rock',   floor=['beam', 'barrel'], hang=['lantern'], wall=['pipe'], water=True),
    'heart':     dict(rock='#262640', back='#1a1838', pattern='crystal',floor=['crystal', 'crystal', 'beam'], hang=['glowworm', 'lantern'], wall=[]),
    'seam':      dict(rock='#2c2838', back='#1e1a2c', pattern='crystal',floor=['crystal', 'beam', 'cart'], hang=['lantern'], wall=['pickaxe'], rails=True),
    'workings':  dict(rock='#34302c', back='#25211d', pattern='rock',   floor=['beam', 'crate', 'beam'], hang=['lantern'], wall=['pickaxe']),
    'drift':     dict(rock='#36322e', back='#221e1b', pattern='rock',   floor=['beam', 'bones', 'crate'], hang=['chain'], wall=[]),
    'cache':     dict(rock='#3a3020', back='#3a2e18', pattern='gold',   floor=['crate'], hang=['lantern'], wall=[]),
    # Hollow Marsh: bog
    'reedbed':   dict(rock='#2c3326', back='#1c2a1e', pattern='roots',  floor=['reeds', 'reeds', 'boat'], hang=['roots'], wall=[], water=True),
    'boathouse': dict(rock='#33302a', back='#2e261c', pattern='plank',  floor=['boat', 'barrel', 'crate'], hang=['lantern'], wall=['net']),
    'roost':     dict(rock='#33302a', back='#24261e', pattern='roots',  floor=['bones', 'reeds'], hang=['roots', 'vine'], wall=[]),
    'lanterns':  dict(rock='#2c3326', back='#262418', pattern='roots',  floor=['candles'], hang=['lantern', 'lantern', 'lantern'], wall=[]),
    'frogpond':  dict(rock='#2c3326', back='#1a2a20', pattern='moss',   floor=['reeds', 'mushroom'], hang=['vine'], wall=[], water=True),
    'willow':    dict(rock='#2c3326', back='#20281c', pattern='roots',  floor=['mushroom', 'reeds'], hang=['vine', 'roots'], wall=[]),
    'mushrooms': dict(rock='#2e2a34', back='#221c2c', pattern='moss',   floor=['mushroom', 'mushroom', 'mushroom'], hang=['glowworm'], wall=[]),
    'eelpool':   dict(rock='#24302e', back='#142624', pattern='moss',   floor=['reeds'], hang=['roots'], wall=[], water=True),
    'smugglers': dict(rock='#33302a', back='#2c2218', pattern='plank',  floor=['crate', 'barrel', 'crate', 'boat'], hang=['lantern'], wall=['net']),
    'glowworms': dict(rock='#262a34', back='#141a26', pattern='rock',   floor=['mushroom'], hang=['glowworm', 'glowworm'], wall=[]),
    'mire':      dict(rock='#2c3326', back='#1e2418', pattern='roots',  floor=['barrel', 'bones'], hang=['roots'], wall=[]),
    'bonepit':   dict(rock='#36302a', back='#2a2420', pattern='skulls', floor=['bones', 'bones'], hang=['chain'], wall=[]),
    'shrine':    dict(rock='#2c3326', back='#22282a', pattern='brick',  floor=['statue', 'candles', 'urn'], hang=['vine'], wall=['torch']),
    'drowned':   dict(rock='#24302e', back='#1a2228', pattern='tile',   floor=['pillar', 'candles', 'pillar'], hang=['chandelier'], wall=['window'], water=True),
    'rootmaze':  dict(rock='#2c2a22', back='#1e1c14', pattern='roots',  floor=['mushroom'], hang=['roots', 'roots'], wall=[]),
    'rootheart': dict(rock='#2c2a22', back='#2a1c14', pattern='roots',  floor=['mushroom', 'totem'], hang=['roots', 'glowworm'], wall=[]),
    'blackwater':dict(rock='#20262a', back='#10181c', pattern='moss',   floor=['reeds', 'bones'], hang=['glowworm'], wall=[], water=True),
    'well':      dict(rock='#33302a', back='#262420', pattern='brick',  floor=['barrel', 'urn'], hang=['chain'], wall=['torch']),
    'landing':   dict(rock='#33302a', back='#28241c', pattern='plank',  floor=['crate', 'barrel'], hang=['lantern'], wall=['net']),
    'tree':      dict(rock='#3a2a1c', back='#2e2014', pattern='bark',   floor=['mushroom'], hang=['roots', 'glowworm'], wall=[]),
}

g = []
LADDERS = []
DOORS = []
ROOMS = []
AREAS = []
DECOR = []
rng = random.Random(1)


class Room:
    def __init__(self, name, x0, x1, top, floor, kit, shape):
        self.name, self.x0, self.x1, self.top, self.floor, self.kit, self.shape = name, x0, x1, top, floor, kit, shape
        self.stand = floor - 1
        self.h = floor - top
        self.res = set()   # columns kept clear on the stand row (doorways, ladders, shafts)

    def has(self, x, y=None):
        return self.x0 <= x <= self.x1 and (y is None or self.top <= y <= self.floor)


def reset(seed):
    global g, LADDERS, DOORS, ROOMS, AREAS, DECOR, rng
    g = [['#'] * W for _ in range(H)]
    LADDERS, DOORS, ROOMS, AREAS, DECOR = [], [], [], [], []
    rng = random.Random(seed)


def put(x, y, ch):
    assert 0 <= x < W and 0 <= y < H, (x, y)
    g[y][x] = ch


def get(x, y):
    return g[y][x]


def rect(x, y, w, h, ch):
    for j in range(y, y + h):
        for i in range(x, x + w):
            put(i, j, ch)


def carve(x, y, w, h):
    rect(x, y, w, h, '.')


def hline(x0, x1, y, ch):
    for x in range(x0, x1 + 1):
        put(x, y, ch)


def vline(x, y0, y1, ch):
    for y in range(y0, y1 + 1):
        put(x, y, ch)


def shards(x0, x1, y, step=1):
    for x in range(x0, x1 + 1, step):
        if g[y][x] == '.':
            put(x, y, 'o')


def camp():
    """The Skyship Camp is the same on every map: x 59..91 on the surface."""
    carve(1, 0, W - 2, SURF)
    put(70, 21, 'S'); put(75, 21, 'V'); put(81, 21, 'N'); put(72, 21, 'k')
    hline(67, 70, 19, '=')
    hline(73, 77, 16, '='); put(75, 15, 'v')
    hline(79, 84, 13, '='); put(81, 12, 'E')
    put(64, 21, 'v'); put(88, 21, 'v')


# ------------------------------------------------------------------ rooms and links

def room(name, x0, x1, top, floor, kit, shape='box'):
    carve(x0, top, x1 - x0 + 1, floor - top)
    r = Room(name, x0, x1, top, floor, kit, shape)
    if shape == 'arch' and r.h >= 6:          # stepped vault corners
        hline(x0, x0 + 2, top, '#'); hline(x1 - 2, x1, top, '#')
        put(x0, top + 1, '#'); put(x1, top + 1, '#')
    elif shape == 'cave':                     # lumpy ceiling and rounded corners
        depth = max(0, min(2, r.h - 5))
        d = 0
        for x in range(x0, x1 + 1):
            d = max(0, min(depth, d + rng.choice((-1, 0, 0, 1))))
            edge = min(x - x0, x1 - x)
            dd = max(d, 2 - edge) if depth else d
            for y in range(top, top + min(dd, depth if depth else 0)):
                put(x, y, '#')
    k = KITS[kit]
    ROOMS.append(r)
    AREAS.append((name, x0 - 1, top - 1, x1 + 1, floor, k['rock'], k['back'], k['pattern']))
    return r


def reserve(r, *xs):
    for x in xs:
        r.res.add(x)


def link_side(a, b, ch='.'):
    """Doorway 3 tall through the wall between a (west) and b (east), standing on the shared floor."""
    assert a.floor == b.floor and a.x1 < b.x0, (a.name, b.name)
    for x in range(a.x1 + 1, b.x0):
        for y in range(a.stand - 2, a.stand + 1):
            put(x, y, ch)
    reserve(a, a.x1 - 1, a.x1); reserve(b, b.x0, b.x0 + 1)


def link_step(a, b, ch='.'):
    """Doorway between side-by-side rooms whose floors differ by up to 3: the doorway drops to the lower floor."""
    assert a.x1 < b.x0 and abs(a.floor - b.floor) <= 3, (a.name, b.name)
    hi, lo = min(a.stand, b.stand), max(a.stand, b.stand)
    for x in range(a.x1 + 1, b.x0):
        for y in range(hi - 2, lo + 1):
            put(x, y, ch)
    reserve(a, a.x1 - 1, a.x1); reserve(b, b.x0, b.x0 + 1)


def balcony_side(a, hall, y, west=True):
    """Doorway from room a into a tall hall, onto the hall's balcony plank at row y (= a.floor)."""
    assert a.floor == y
    xs = range(a.x1 + 1, hall.x0) if west else range(hall.x1 + 1, a.x0)
    for x in xs:
        for yy in range(a.stand - 2, a.stand + 1):
            put(x, yy, '.')
    if west:
        reserve(a, a.x1 - 1, a.x1)
    else:
        reserve(a, a.x0, a.x0 + 1)


def ladder(x, y_top, r_bottom):
    """Ladder from row y_top down to the bottom room's stand row; keeps the column clear in every room it crosses."""
    LADDERS.append((x, y_top, r_bottom.stand))
    for r in ROOMS:
        if r.has(x) and r.floor >= y_top and r.top <= r_bottom.floor:
            reserve(r, x - 1, x, x + 1)


def link_down(a, b, x):
    assert a.has(x) and b.has(x), (a.name, b.name, x)
    ladder(x, a.floor, b)


def entrance(x, r, door=None):
    ladder(x, SURF, r)
    if door:
        DOORS.append((x, SURF, door))


def free_cols(r):
    return [x for x in range(r.x0, r.x1 + 1)
            if x not in r.res and get(x, r.stand) == '.' and get(x, r.floor) == '#']


def spot(r, ch, x):
    """Put a marker on the stand row (or at the nearest free column)."""
    cols = free_cols(r)
    assert cols, r.name
    x = min(cols, key=lambda c: abs(c - x))
    put(x, r.stand, ch)
    reserve(r, x)
    return x


def furnish(r, items='', spikes=1, ledges=None, ledge_item='', step=3):
    """Spikes, items spread along the floor, plank ledges with shards, loose shards."""
    for _ in range(spikes):
        cols = free_cols(r)
        runs = [x for x in cols if all(x + k in cols for k in range(6)) and r.x0 + 4 < x < r.x1 - 8]
        if runs:
            x = rng.choice(runs) + 2
            put(x, r.stand, '^'); put(x + 1, r.stand, '^')
            reserve(r, x - 1, x, x + 1, x + 2)
    cols = free_cols(r)
    for i, ch in enumerate(items):
        if cols:
            x = cols[min(len(cols) - 1, (i + 1) * len(cols) // (len(items) + 1))]
            put(x, r.stand, ch); reserve(r, x)
            cols = free_cols(r)
    n = ledges if ledges is not None else (0 if r.h < 6 else 1 + (r.x1 - r.x0) // 24)
    width = r.x1 - r.x0
    for i in range(n):
        cx = r.x0 + (i + 1) * width // (n + 1)
        y = r.stand - 2   # plank row: standing on it is 3 rows up
        x0, x1 = cx - 2, cx + 2
        if all(get(x, y) == '.' and get(x, y - 1) == '.' and get(x, y - 2) == '.' for x in range(x0, x1 + 1)):
            hline(x0, x1, y, '=')
            shards(x0, x1, y - 1, 2)
            if i < len(ledge_item):
                put(cx, y - 1, ledge_item[i])
    for x in free_cols(r)[1::step]:
        put(x, r.stand, 'o')


def hall(r, plank_rows, balconies, items='', step=3):
    """A tall hall climbed by zig-zag planks; balconies are full-width planks at the floors of the rooms beside it."""
    cx = (r.x0 + r.x1) // 2
    for i, y in enumerate(plank_rows):
        if y in balconies:
            hline(r.x0, r.x1, y, '=')
            shards(r.x0 + 1, r.x1 - 1, y - 1, 4)
        else:
            a, b = (max(r.x0, cx - 6), cx) if i % 2 == 0 else (cx, min(r.x1, cx + 6))
            hline(a, b, y, '=')
            shards(a, b, y - 1, 3)
    furnish(r, items, spikes=0, ledges=0, step=step)


def bridge_pit(r, x0, x1):
    """A chasm in the room's floor crossed by the rope bridge; the repair lever stands west of it."""
    carve(x0, r.floor, x1 - x0 + 1, 2)
    hline(x0, x1, r.floor + 2, '^')
    hline(x0, x1, r.floor, 'B')
    put(x0 - 2, r.stand, 'Y')
    reserve(r, *range(x0 - 3, x1 + 2))


def slab_pit(r, x0):
    """An 8-wide spike pit in the floor crossed by the moving slab."""
    carve(x0, r.floor, 8, 3)
    hline(x0, x0 + 7, r.floor + 3, '^')
    put(x0, r.floor, 'M'); put(x0 + 5, r.floor, 'm')
    reserve(r, *range(x0 - 1, x0 + 9))


def lift(x, bottom, gear_x):
    """3-wide lift shaft from the surface down to room `bottom`'s floor."""
    carve(x, SURF, 3, bottom.floor - SURF + 2)
    put(x, SURF, 'U'); put(x, bottom.floor, 'u'); put(gear_x, SURF - 1, 'G')
    for r in ROOMS:
        if r.has(x) or r.has(x + 2):
            reserve(r, *range(x - 1, x + 4))


def secret(a, b):
    """A false wall between a and b: looks like rock, walk straight through."""
    link_side(a, b, 'F')


# ------------------------------------------------------------------ decor

def decorate():
    for r in ROOMS:
        k = KITS[r.kit]
        cols = [x for x in range(r.x0, r.x1 + 1) if x not in r.res and get(x, r.floor) == '#']
        if k.get('water'):
            DECOR.append(['water', r.x0, r.stand, r.x1])
        if k.get('rails'):
            DECOR.append(['rails', r.x0, r.stand, r.x1])
        if k['floor']:
            x = r.x0 + 2
            i = 0
            while x <= r.x1 - 1:
                if x in cols:
                    kind = k['floor'][i % len(k['floor'])]
                    DECOR.append([kind, x, r.stand, r.h])
                    i += 1
                    x += rng.randint(5, 8)
                else:
                    x += 1
        if k['hang']:
            for i, x in enumerate(range(r.x0 + 3, r.x1 - 1, rng.randint(6, 8))):
                y = r.top
                while y < r.stand and get(x, y) == '#':
                    y += 1
                if get(x, y) == '.' and get(x, y - 1) == '#' and y < r.stand - 2:
                    DECOR.append([k['hang'][i % len(k['hang'])], x, y, 0])
        if k['wall'] and r.h >= 5:
            for i, x in enumerate(range(r.x0 + 5, r.x1 - 2, 11)):
                DECOR.append([k['wall'][i % len(k['wall'])], x, r.stand - 2, 0])


def surface_decor(items):
    for kind, x, extra in items:
        DECOR.append([kind, x, SURF - 1, extra or 4])


def finish():
    for x, y0, y1 in LADDERS:
        vline(x, y0, y1, 'H')
    for x, y, ch in DOORS:
        put(x, y, ch)
    rect(0, 0, 1, H, '#'); rect(W - 1, 0, 1, H, '#'); rect(0, H - 2, W, 2, '#')
    decorate()
    return [''.join(r) for r in g]


def write(map_id, cls, name, blurb, rows, surface_areas, catch_all, theme):
    OUT.mkdir(parents=True, exist_ok=True)
    body = '\n'.join(rows)
    areas = list(AREAS) + surface_areas + [catch_all]
    area_s = ',\n\t'.join(f'["{n}", {a}, {b}, {c}, {d}, "{rock}", "{back}", "{pat}"]' for n, a, b, c, d, rock, back, pat in areas)
    decor_s = ',\n\t'.join(f'["{k}", {x}, {y}, {e}]' for k, x, y, e in DECOR)
    theme_s = ', '.join(f'"{k}": {v!r}'.replace("'", '"') for k, v in theme.items())
    (OUT / f'cf_map_{map_id}.gd').write_text(
        f'class_name {cls}\n'
        '## Generated by tools/build_maps.py, but this ASCII is what the game loads.\n'
        '## Edit either, then run tools/check_map.py to prove the level is still fully reachable.\n\n'
        f'const ID := "{map_id}"\nconst NAME := "{name}"\nconst BLURB := "{blurb}"\n'
        f'const WIDTH := {W}\nconst HEIGHT := {H}\n\n'
        '## Rooms first, then surface zones, then an unnamed catch-all for the rock and tunnels between rooms.\n'
        '## [name, x0, y0, x1, y1 (tiles, inclusive), rock colour, wall colour, back-wall pattern]\n'
        f'const AREAS := [\n\t{area_s},\n]\n\n'
        '## Scenery props: [kind, tile x, tile y (stand row, or top row for hanging), extra (room height, or end x)]\n'
        f'const DECOR := [\n\t{decor_s},\n]\n\n'
        f'const THEME := {{{theme_s}}}\n\n'
        f'const MAP := """{body}"""\n')
    print(f'wrote cf_map_{map_id}.gd: {len(ROOMS)} rooms, {len(DECOR)} props')


# ==================================================================== 1. Verdant Reach: the sunken temple
def verdant():
    reset(11)
    camp()
    # ---------------- surface: the Verdant Ruins (west) and the Crown Spire (east)
    carve(51, 22, 8, 3); hline(51, 58, 25, '^'); put(51, 22, 'M'); put(56, 22, 'm')   # slab over a spike pit
    shards(52, 57, 20)
    rect(40, 17, 3, 5, '#'); hline(43, 45, 19, '='); hline(37, 39, 19, '='); shards(40, 42, 16)
    hline(29, 30, 21, '^'); put(24, 21, 'C')
    hline(23, 26, 19, '='); hline(18, 21, 16, '='); hline(13, 17, 13, '='); hline(6, 11, 10, '=')
    put(8, 9, 'R'); shards(23, 26, 18); shards(18, 21, 15); shards(13, 17, 12, 2)
    hline(6, 8, 19, '='); rect(10, 17, 8, 5, '#'); carve(12, 18, 5, 4); rect(10, 18, 2, 4, 'F'); put(15, 21, 'K'); put(13, 21, 'o')
    shards(3, 5, 21); shards(44, 50, 21, 2); put(47, 21, 'O'); put(38, 21, 'k'); put(27, 21, 'X'); put(16, 12, 'X')
    hline(94, 97, 21, 't'); shards(93, 98, 20)
    carve(100, 22, 10, 3); hline(100, 109, 25, '^'); hline(100, 109, 22, 'B'); put(98, 21, 'Y'); shards(101, 108, 20, 2)
    put(112, 21, 'k'); put(117, 21, 'C')
    hline(113, 116, 19, '='); hline(117, 120, 16, '='); hline(121, 124, 13, '=')
    shards(113, 116, 18); shards(117, 120, 15); shards(121, 124, 12)
    rect(128, 5, 9, 17, '#'); LADDERS.append((127, 5, 21)); LADDERS.append((137, 5, 21)); put(134, 4, 'R'); shards(129, 133, 4); put(131, 4, 'W')
    put(126, 21, 'O'); shards(143, 147, 21)
    put(123, 22, '='); carve(123, 23, 1, 4)          # one-way chute down into the Greenhouse
    surface_decor([('pillar', 4, 0), ('statue', 20, 0), ('pillar', 33, 0), ('urn', 46, 0), ('pillar', 92, 0), ('statue', 119, 0), ('urn', 146, 0)])

    # ---------------- the temple below
    A, B, C = (27, 33), (37, 45), (50, 59)
    cellar = room('Root Cellar', 2, 20, *A, 'cellar', 'cave')
    library = room('Old Library', 23, 50, *A, 'library')
    chapel = room('Chapel', 53, 97, *A, 'chapel', 'arch')
    cloister = room('Cloister', 100, 118, *A, 'cloister', 'arch')
    green = room('Greenhouse', 121, 146, *A, 'greenhouse')
    crypt = room('Flooded Crypt', 2, 28, *B, 'crypt', 'arch')
    ossuary = room('Ossuary', 31, 54, *B, 'ossuary')
    sanctum = room('Great Sanctum', 57, 93, B[0], C[1], 'sanctum', 'arch')     # two storeys tall
    mine = room('Shard Mine', 96, 146, *B, 'shardmine', 'cave')
    reliq = room('Reliquary', 2, 6, *C, 'reliquary')
    catac = room('Catacombs', 9, 54, *C, 'catacomb', 'arch')
    spring = room('Deep Spring', 96, 146, *C, 'spring', 'cave')

    link_side(cellar, library); link_side(library, chapel); link_side(chapel, cloister); link_side(cloister, green)
    link_side(crypt, ossuary)
    balcony_side(ossuary, sanctum, B[1], west=True)
    for y in range(B[1] - 3, B[1]):                   # gate 2: from the Shard Mine onto the east balcony
        put(94, y, '2'); put(95, y, '2')
    secret(reliq, catac)
    for x in (55, 56):                                # Catacombs ↔ Sanctum floor
        for y in range(C[1] - 3, C[1]):
            put(x, y, '.')
    reserve(catac, 53, 54)
    for x in (94, 95):                                # Sanctum floor ↔ Deep Spring
        for y in range(C[1] - 3, C[1]):
            put(x, y, '.')
    reserve(spring, 96, 97); reserve(mine, 96, 97)

    entrance(6, cellar); entrance(34, library)
    entrance(77, chapel, '1'); spot(chapel, 'p', 88)
    lift(140, mine, 145)
    link_down(cellar, crypt, 12); link_down(library, ossuary, 44); link_down(green, mine, 128); link_down(cloister, mine, 104)
    ladder(75, A[1], sanctum)                         # the temple stair: Chapel down the middle of the Sanctum
    link_down(crypt, catac, 20); link_down(ossuary, catac, 48); link_down(mine, spring, 132)
    entrance(114, spring, '3'); spot(spring, 'r', 110)  # express shaft, opened from the Deep Spring
    spot(mine, 'q', 100)

    hall(sanctum, [56, 53, 50, 47, 45, 42, 39], [45], items='OIC', step=4)
    furnish(cellar, 'XO', spikes=0)
    furnish(library, 'CX', ledge_item='R')
    furnish(chapel, 'XkC', spikes=1)
    furnish(cloister, 'O', spikes=0)
    furnish(green, 'XC', spikes=1, ledge_item='O')
    furnish(crypt, 'RX', spikes=1)
    furnish(ossuary, 'WCk', spikes=1)
    furnish(mine, 'XCkWX', spikes=1, ledge_item='RO')
    furnish(reliq, 'K', spikes=0, ledges=0)
    furnish(catac, 'XWkC', spikes=1, ledge_item='O')
    furnish(spring, 'XRWO', spikes=1, ledge_item='C')

    rows = finish()
    write('verdant', 'CFMapVerdant', 'Verdant Reach',
          'Ruins on the surface, a sunken temple below: a library, a chapel, flooded crypts and the two-storey Great Sanctum where the Heartstone rests.',
          rows,
          [("Skyship Camp", 59, 0, 91, 21, "#3d2b22", "#22201c", "none"), ("Verdant Ruins", 1, 0, 58, 21, "#3d2b22", "#22201c", "none"),
           ("Crown Spire", 92, 0, 148, 21, "#3a2c26", "#22201c", "none")],
          ("", 0, 22, 149, 63, "#352c26", "#201b18", "rock"),
          {"sky": ["#0c2b3a", "#245a57", "#c98f4e", "#f0c46a"], "hills": ["#1d4a4e", "#16393b", "#10302f"],
           "grass": ["#3f7d33", "#5fae4a", "#86d45c"], "sun": "#ffd38a", "flies": "#d8ff8a", "skyline": "ruins"})


# ==================================================================== 2. Shard Mines: the V-shaped decline
def mines():
    reset(22)
    camp()
    # ---------------- surface: the headframe yard and spoil heaps
    shards(12, 56, 21, 4); shards(94, 133, 21, 4)
    put(30, 21, 'X'); put(52, 21, 'O'); put(116, 21, 'C'); put(124, 21, 'k')
    hline(110, 114, 18, '='); shards(110, 114, 17)
    hline(40, 46, 18, '='); hline(46, 50, 15, '='); put(48, 14, 'R'); shards(40, 45, 17, 2)
    surface_decor([('headframe', 16, 0), ('cart', 34, 0), ('crate', 44, 0), ('headframe', 86, 0), ('heap', 100, 0), ('cart', 106, 0), ('heap', 128, 0), ('heap', 141, 0)])

    # two declines step down from the map's edges and meet at the Crystal Heart; the Main Shaft drops straight down the middle
    # west decline
    adit = room('West Adit', 2, 15, 25, 30, 'orechute')
    lamp = room('Lamp Room', 18, 31, 28, 33, 'lamproom')
    depot = room('Cart Depot', 34, 55, 31, 36, 'depot')
    pump = room('Pump House', 26, 52, 41, 47, 'pumphouse')
    works = room('Old Workings', 2, 23, 44, 50, 'workings', 'cave')
    seam = room('Deep Seam', 2, 30, 53, 60, 'seam', 'cave')
    # the middle
    office = room("Foreman's Office", 60, 92, 27, 33, 'office')
    heart = room('Crystal Heart', 34, 116, 53, 60, 'heart', 'cave')
    # east decline
    powder = room('Powder Store', 96, 109, 31, 36, 'powder')
    chute = room('Ore Chute', 112, 131, 28, 33, 'orechute')
    spoil = room('East Adit', 134, 147, 25, 30, 'depot')
    smelter = room('Smelter', 95, 128, 40, 46, 'smelter')
    flood = room('Flooded Shaft', 131, 147, 43, 49, 'floodshaft')
    drift = room('Collapsed Drift', 119, 141, 53, 60, 'drift', 'cave')
    cache = room('Lost Cache', 144, 147, 55, 60, 'cache')

    link_step(adit, lamp); link_step(lamp, depot); link_step(depot, office)
    link_step(works, pump)
    link_side(seam, heart); link_side(heart, drift)
    link_step(office, powder); link_step(powder, chute); link_step(chute, spoil)
    link_step(smelter, flood, '2'); spot(flood, 'q', 136)
    secret(drift, cache)

    lift(85, heart, 90)                               # the Main Shaft: camp to the bottom in one ride
    entrance(8, adit); entrance(144, spoil)
    entrance(77, office, '1'); spot(office, 'p', 65)
    entrance(138, drift, '3'); spot(drift, 'r', 125)  # express from the deepest drift
    link_down(depot, pump, 50); link_down(lamp, works, 20); link_down(works, seam, 10)
    link_down(chute, smelter, 125); link_down(powder, smelter, 100); link_down(flood, drift, 135)
    link_down(smelter, heart, 106)
    ladder(70, office.floor, heart)                   # the cage ladder beside the shaft

    bridge_pit(depot, 40, 49)
    slab_pit(pump, 36)
    hline(102, 105, powder.stand, 't')                # the powder store's trapped floor
    reserve(powder, *range(101, 107))

    furnish(adit, 'XO', spikes=0)
    furnish(lamp, 'CX', spikes=0)
    furnish(depot, 'Ok', spikes=0)
    furnish(pump, 'XC', spikes=0)
    furnish(works, 'XkO', spikes=1)
    furnish(seam, 'WRX', spikes=1, ledge_item='O')
    furnish(office, 'kCX', spikes=1, ledge_item='R')
    furnish(heart, 'XWOIkCWX', spikes=3, ledge_item='ROC')
    furnish(powder, 'OX', spikes=0)
    furnish(chute, 'XC', spikes=1)
    furnish(spoil, 'OC', spikes=0)
    furnish(smelter, 'XkCW', spikes=1, ledge_item='O')
    furnish(flood, 'RX', spikes=1)
    furnish(drift, 'XOR', spikes=1, ledge_item='C')
    furnish(cache, 'K', spikes=0, ledges=0)

    rows = finish()
    write('mines', 'CFMapMines', 'Shard Mines',
          'A V-shaped mine under a night sky: two long declines of rooms step down from the edges to the wide Crystal Heart, and the Main Shaft lift drops straight there from camp.',
          rows,
          [("Skyship Camp", 59, 0, 91, 21, "#3a3438", "#1c1a20", "none"), ("Headframe Yard", 1, 0, 58, 21, "#3a3438", "#1c1a20", "none"),
           ("Spoil Heaps", 92, 0, 148, 21, "#3a3438", "#1c1a20", "none")],
          ("", 0, 22, 149, 63, "#2e2c34", "#1a1a22", "rock"),
          {"sky": ["#070b1a", "#141c3a", "#3a3f6e", "#6a6fa0"], "hills": ["#1a1f38", "#141830", "#0e1226"],
           "grass": ["#3a5a4a", "#4f7a5c", "#6a9a70"], "sun": "#a0b8ff", "flies": "#9fe8ff", "skyline": "mine"})


# ==================================================================== 3. Hollow Marsh: the bog and the Hollow Tree
def marsh():
    reset(33)
    camp()
    # ---------------- surface: West Bog and East Bog
    for x0 in (13, 20, 120, 131):
        carve(x0, 22, 3, 2); hline(x0, x0 + 2, 24, '^')
    carve(28, 22, 8, 3); hline(28, 35, 25, '^'); put(28, 22, 'M'); put(33, 22, 'm'); shards(29, 34, 20)
    hline(94, 97, 21, 't')
    carve(100, 22, 10, 3); hline(100, 109, 25, '^'); hline(100, 109, 22, 'B'); put(98, 21, 'Y')
    hline(25, 29, 18, '='); put(27, 17, 'R'); hline(8, 11, 18, '='); shards(8, 11, 17)
    hline(112, 116, 18, '='); shards(112, 116, 17); put(125, 21, 'C'); put(3, 21, 'O'); put(17, 21, 'X'); put(138, 21, 'X')
    shards(4, 11, 21, 2); shards(37, 42, 21, 2); shards(92, 98, 20, 2); shards(110, 118, 21, 2)
    surface_decor([('reeds', 6, 0), ('deadtree', 24, 0), ('reeds', 40, 0), ('hut', 92, 0), ('reeds', 117, 0), ('deadtree', 128, 0), ('reeds', 146, 0)])

    A, B, C, D = (27, 33), (37, 42), (46, 51), (55, 60)
    reed = room('Reed Bed', 2, 20, *A, 'reedbed', 'cave')
    boat = room('Old Boathouse', 23, 41, *A, 'boathouse')
    tree = room('Hollow Tree', 44, 54, SURF + 1, D[1], 'tree')                 # surface to the bottom
    heron = room('Heron Roost', 57, 68, *A, 'roost', 'cave')
    lant = room('Lantern Hollow', 71, 92, *A, 'lanterns', 'cave')
    frog = room('Frog Pond', 95, 116, *A, 'frogpond', 'cave')
    willow = room('Willow Hall', 119, 138, *A, 'willow', 'cave')
    mush = room('Mushroom Grove', 2, 22, *B, 'mushrooms', 'cave')
    eel = room('Eel Pool', 25, 41, *B, 'eelpool', 'cave')
    smug = room("Smugglers' Den", 57, 76, *B, 'smugglers')
    glow = room('Glowworm Grotto', 79, 104, *B, 'glowworms', 'cave')
    mire = room('Mire Cellar', 107, 138, *B, 'mire', 'cave')
    bone = room('Bone Pit', 2, 18, *C, 'bonepit', 'cave')
    shrine = room('Sunken Shrine', 21, 41, *C, 'shrine', 'arch')
    drowned = room('Drowned Chapel', 57, 92, *C, 'drowned', 'arch')
    rootm = room('Root Maze', 95, 138, *C, 'rootmaze', 'cave')
    rheart = room('Rootheart', 2, 41, *D, 'rootheart', 'cave')
    black = room('Black Water', 57, 92, *D, 'blackwater', 'cave')
    well = room('Old Well', 95, 118, *D, 'well')
    landing = room('Lift Landing', 121, 146, *D, 'landing')

    # the tree is open at the top: planks you can drop through, climbed by ledges inside
    hline(44, 54, SURF, '=')
    # doorways into the trunk at each level
    balcony_side(boat, tree, A[1], west=True); balcony_side(heron, tree, A[1], west=False)
    balcony_side(eel, tree, B[1], west=True); balcony_side(smug, tree, B[1], west=False)
    balcony_side(shrine, tree, C[1], west=True)
    balcony_side(black, tree, D[1], west=False)
    for x in (42, 43):                                # Rootheart ↔ tree floor
        for y in range(D[1] - 3, D[1]):
            put(x, y, '.')
    reserve(rheart, 40, 41)

    link_side(reed, boat); link_side(lant, frog); link_side(frog, willow)
    link_side(mush, eel); link_side(smug, glow)
    link_side(glow, mire, '2'); spot(mire, 'q', 110)
    secret(bone, shrine)
    link_side(drowned, rootm)
    link_side(black, well); link_side(well, landing)

    entrance(5, reed); entrance(130, willow)
    entrance(77, lant, '1'); spot(lant, 'p', 88)
    entrance(38, rheart, '3'); spot(rheart, 'r', 6)
    lift(141, landing, 146)
    link_down(reed, mush, 10); link_down(frog, glow, 100); link_down(willow, mire, 128)
    link_down(mush, bone, 12); link_down(glow, drowned, 85); link_down(mire, rootm, 125)
    link_down(drowned, black, 70); link_down(rootm, well, 105); link_down(shrine, rheart, 30)

    hall(tree, [57, 54, 51, 48, 45, 42, 39, 36, 33, 30, 27, 25], [51, 42, 33], items='XO', step=3)
    furnish(reed, 'XO', spikes=1)
    furnish(boat, 'CX', spikes=0, ledge_item='O')
    furnish(heron, 'WR', spikes=0)                    # a dead end off the tree
    furnish(lant, 'kXC', spikes=1)
    furnish(frog, 'XO', spikes=1)
    furnish(willow, 'CRk', spikes=1)
    furnish(mush, 'XC', spikes=1)
    furnish(eel, 'O', spikes=0)
    furnish(smug, 'CKO', spikes=0)
    furnish(glow, 'XkO', spikes=1)
    furnish(mire, 'WCX', spikes=1)
    furnish(bone, 'RK', spikes=0)                     # behind the false wall
    furnish(shrine, 'WX', spikes=1)
    furnish(drowned, 'XkCO', spikes=1)
    furnish(rootm, 'XOC', spikes=2)
    furnish(rheart, 'IWO', spikes=1)
    furnish(black, 'XRC', spikes=1)
    furnish(well, 'XO', spikes=0)
    furnish(landing, 'kC', spikes=0)

    rows = finish()
    write('marsh', 'CFMapMarsh', 'Hollow Marsh',
          'A misty bog of flooded pools and root chambers, all reached from inside the giant Hollow Tree. Hidden passages, dead ends, a smugglers\\u2019 den.',
          rows,
          [("Skyship Camp", 59, 0, 91, 21, "#2c3326", "#18211b", "none"), ("West Bog", 1, 0, 58, 21, "#2c3326", "#18211b", "none"),
           ("East Bog", 92, 0, 148, 21, "#2c3326", "#18211b", "none")],
          ("", 0, 22, 149, 63, "#2a2e24", "#171c16", "roots"),
          {"sky": ["#1a2a26", "#2f4a3e", "#6a8a6a", "#a8c49a"], "hills": ["#223a32", "#1a2e28", "#142420"],
           "grass": ["#3a6a3a", "#5a8f4a", "#7ab05a"], "sun": "#e6f0c8", "flies": "#c8ff9a", "skyline": "trees"})


if __name__ == '__main__':
    verdant()
    mines()
    marsh()
