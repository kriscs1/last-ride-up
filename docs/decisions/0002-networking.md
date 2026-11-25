# 0002: Authoritative server, client prediction, ENet

**Status:** accepted (2026-11-24)

## Decision
- **Topology:** dedicated headless Godot server; clients never host. `server_relay` is off, so clients can't RPC each other.
- **Transport:** ENet (UDP). Channel 0 carries reliable messages (room, start, items, events). Channel 1 carries unreliable-ordered inputs and snapshots. Channel 2 carries ping.
- **Authority:** the server owns every outcome: roles, Sunstone totals, pickups, hazards, sabotage, timers and wins. Client input is sanitised in `CFInput.from_wire` (clamped, malformed frames dropped).
- **Rates:** simulation 60 Hz; snapshots 20 Hz; inputs batched 2 per packet (30 Hz), each packet repeating the last 4 frames.
- **Own player:** predicted with `CFSim.step_movement`, then reconciled by replaying unacknowledged inputs on each snapshot. Errors under 120 px are smoothed visually.
- **Other players:** interpolated 100 ms behind the estimated server clock.
- **Moving platforms:** taken from the snapshot, then fast-forwarded by half the round trip.
- **Disconnects:** the player freezes in place and the seat is held for 60 s. Reconnecting with the session token resumes the same seat. A leaver drops their Sunstone.
- **Hidden information (Milestone 3):** snapshots and events are built per player in `CFRoom.step`. Role and Guile data must only ever be sent to traitors, and a test will check innocent packets.

## Open questions
- Packing snapshots into bytes once real 4G measurements exist.
- Region hosting and a matchmaking service when there's more than one server.
