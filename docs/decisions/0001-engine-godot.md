# 0001: Build Crownfall in Godot 4

**Status:** accepted (2026-11-24). Replaces the earlier TypeScript plan (Phaser + Colyseus + Capacitor).

## Decision
Use Godot 4 (GDScript) for the client, and run the same project headless as the dedicated server.

## Why
- One engine and one language for client and server. The rules in `scripts/sim` run unchanged on both, which client prediction requires.
- Native Android and iOS exports, without the WebView performance risk on low-end Android.
- Built-in high-level multiplayer (ENet over UDP, RPCs) and a headless dedicated-server export.
- A free engine (MIT licence) with no revenue share, which suits a free-to-play cosmetic model.

## Consequences
- The TypeScript prototype is now reference only. Its rules were ported to GDScript one function at a time, with the same tests.
- No web build for players: ENet doesn't run in browsers. Internal web playtests would need a WebSocket peer.
- GDScript performance is fine for 10 players at 60 Hz. If one server process later hosts many rooms, the hot loop (`_collide`) is the candidate to move to C++ (GDExtension).
