#!/usr/bin/env python3
"""Proves every map in scripts/sim/maps/ is playable, using a conservative movement model
(it under-estimates what players can do, so anything it reaches, a real player can):
  - every Sunstone, job marker, valve, lever and the boarding deck is reachable from spawn
  - from every reachable spot, camp can be reached again with a FULL sack (lower jumps)
  - doors start closed and open once their lever has been reached
Exit code 0 when all checks pass."""
import re, sys, pathlib
from collections import deque

import glob
MAP_FILES = sorted(glob.glob(str(pathlib.Path(__file__).resolve().parent.parent / 'scripts/sim/maps/cf_map_*.gd')))
rows = []
H = W = 0


def load(path):
    global rows, H, W
    src = pathlib.Path(path).read_text()
    rows = re.search(r'"""(.*)"""', src, re.S).group(1).split('\n')
    H, W = len(rows), len(rows[0])
    assert all(len(r) == W for r in rows), 'ragged rows'
    assert (W, H) == (150, 64), 'every map must be 150 x 64'


DOOR_OF_LEVER = {'p': '1', 'q': '2', 'r': '3'}
SOLID = set('#')
ITEMS = set('oOCRKI')
POINTS = ITEMS | set('vEpqrYGNkXW')


def at(x, y):
    if x < 0 or x >= W or y >= H:
        return '#'
    if y < 0:
        return '.'
    return rows[y][x]


def find(ch):
    return [(x, y) for y in range(H) for x in range(W) if rows[y][x] == ch]


def make_world(open_doors):
    def solid(x, y):
        c = at(x, y)
        return c in SOLID or (c in '123' and c not in open_doors)

    def ladder(x, y):
        c = at(x, y)
        if c == 'H':
            return True
        return c in '123' and c in open_doors and (at(x, y + 1) == 'H' or at(x, y - 1) == 'H')

    def passable(x, y):
        return not solid(x, y)

    def support(x, y):  # can a player stand in (x, y)?
        if not passable(x, y) or at(x, y) == '^':
            return False
        if (x, y) in VIRTUAL:
            return True
        b = at(x, y + 1)
        if solid(x, y + 1) or b in '=B':
            return True
        if ladder(x, y):
            return True
        return ladder(x, y + 1) and not ladder(x, y)

    def fall(x, y):
        """Drop from (x, y) until standing; None if the fall ends in spikes."""
        while y < H:
            if at(x, y) == '^':
                return None
            if support(x, y):
                return (x, y)
            y += 1
        return None

    return solid, ladder, passable, support, fall


def neighbours(pos, world, heavy):
    solid, ladder, passable, support, fall = world
    x, y = pos
    out = []
    J = 3 if heavy else 4
    # walk / step off
    for dx in (-1, 1):
        if passable(x + dx, y):
            f = fall(x + dx, y)
            if f:
                out.append(f)
    # jumps: straight up, then across, then fall
    for dy in range(0, J + 1):
        if any(not passable(x, y - k) or at(x, y - k) == '^' for k in range(1, dy + 1)):
            break
        if dy > 0 and not passable(x, y - dy - 1) and dy == J:
            pass
        # horizontal reach by rise (tiles); real jumps go ~6 tiles light / ~5 loaded on the flat
        if dy <= 1:
            reach = 4 if heavy else 5
        elif dy == 2:
            reach = 3 if heavy else 4
        else:
            reach = 2 if heavy else 3
        for sgn in (-1, 1):
            for dx in range(1, reach + 1):
                cx, cy = x + sgn * dx, y - dy
                if not passable(cx, cy) or at(cx, cy) == '^':
                    break
                f = fall(cx, cy)
                if f:
                    out.append(f)
        if dy > 0 and support(x, y - dy):
            out.append((x, y - dy))
    # ladders
    if ladder(x, y) or ladder(x, y + 1):
        if ladder(x, y) and passable(x, y - 1):
            out.append((x, y - 1)) if support(x, y - 1) else None
        if ladder(x, y + 1):
            out.append((x, y + 1))
    # drop through a plank / bridge? (planks only)
    if at(x, y + 1) == '=':
        f = fall(x, y + 2) if passable(x, y + 2) else None
        if f:
            out.append(f)
    # moving slab and lift link their two ends
    for a, b in LINKS:
        if pos == a:
            out.append(b)
        if pos == b:
            out.append(a)
    return out


def bfs(start, open_doors, heavy, reverse=False):
    world = make_world(open_doors)
    if reverse:
        # reverse search: which cells can reach `start`?
        allc = [(x, y) for y in range(H) for x in range(W) if world[3](x, y)]
        rev = {}
        for c in allc:
            for n in neighbours(c, world, heavy):
                rev.setdefault(n, set()).add(c)
        seen = {start}; q = deque([start])
        while q:
            c = q.popleft()
            for p in rev.get(c, ()):
                if p not in seen:
                    seen.add(p); q.append(p)
        return seen
    seen = {start}; q = deque([start])
    while q:
        c = q.popleft()
        for n in neighbours(c, world, heavy):
            if n not in seen:
                seen.add(n); q.append(n)
    return seen


REQUIRED_ONE = 'SVNEYGMmUupqrI'


def check():
    global LINKS, VIRTUAL
    for ch in REQUIRED_ONE:
        if len(find(ch)) != 1:
            return [f'needs exactly one {ch!r}, found {len(find(ch))}']
    for ch, n in (('v', 3), ('1', 1), ('2', 1), ('3', 1), ('B', 1), ('t', 1), ('k', 4), ('X', 6), ('W', 3)):
        if len(find(ch)) < n:
            return [f'needs at least {n} {ch!r}, found {len(find(ch))}']
    M = find('M'); m = find('m'); U = find('U'); u = find('u')
    LINKS = []
    VIRTUAL = set()   # cells over the slab's path count as standable (you can ride it there)
    if M and m:
        VIRTUAL |= {(x, M[0][1] - 1) for x in range(M[0][0], m[0][0] + 3)}
    if U and u:   # the lift waits at both ends
        VIRTUAL |= {(x, U[0][1] - 1) for x in range(U[0][0], U[0][0] + 3)} | {(x, u[0][1] - 1) for x in range(u[0][0], u[0][0] + 3)}
    if M and m:
        LINKS.append(((M[0][0] - 1, M[0][1] - 1), (m[0][0] + 3, m[0][1] - 1)))
    if U and u:
        LINKS.append(((U[0][0] - 1, U[0][1] - 1), (u[0][0] + 1, u[0][1] - 1)))
        LINKS.append(((U[0][0] + 3, U[0][1] - 1), (u[0][0] + 1, u[0][1] - 1)))

    spawn = find('S')[0]
    problems = []

    # doors open as their levers become reachable
    open_doors = set()
    while True:
        reach = bfs(spawn, open_doors, heavy=False)
        newly = {DOOR_OF_LEVER[at(x, y)] for (x, y) in reach if at(x, y) in DOOR_OF_LEVER} - open_doors
        if not newly:
            break
        open_doors |= newly
    print(f'doors opened by reachable levers: {sorted(open_doors)}')
    for d in '123':
        if find(d) and d not in open_doors:
            problems.append(f'door {d} can never be opened')

    def collectable(p):
        # floating pickups are grabbed by jumping: any reachable standing spot up to 3 below, clear column
        x, y = p
        for k in range(0, 4):
            if (x, y + k) in reach:
                return True
            if at(x, y + k + 1) == '#':
                return False
        return False


    for ch in sorted(POINTS):
        for p in find(ch):
            if not collectable(p):
                problems.append(f'{ch} at {p} is unreachable from spawn')

    # no softlocks: from everywhere reachable, camp is reachable carrying a full sack
    home = bfs(spawn, open_doors, heavy=True, reverse=True)
    stuck = [c for c in reach if c not in home]
    if stuck:
        problems.append(f'{len(stuck)} reachable spots cannot get home fully loaded, e.g. {sorted(stuck)[:8]}')

    # early game: before any door is opened, every area still has a way home
    home0 = bfs(spawn, set(), heavy=True, reverse=True)
    reach0 = bfs(spawn, set(), heavy=False)
    stuck0 = [c for c in reach0 if c not in home0]
    if stuck0:
        problems.append(f'{len(stuck0)} spots are one-way before shortcuts open, e.g. {sorted(stuck0)[:8]}')

    total = sum(len(find(c)) for c in 'oOCRKI')
    print(f'map {W}x{H}: {len(reach)} standing spots reachable, {total} Sunstone spots, {len(find("k"))} checkpoints')
    print('\n'.join(problems) if problems else 'map check: all reachable, no softlocks')
    return problems


failed = False
for path in MAP_FILES:
    load(path)
    print(f'--- {pathlib.Path(path).name}')
    probs = check()
    if probs:
        failed = True
        print('\n'.join(probs))
sys.exit(1 if failed else 0)
