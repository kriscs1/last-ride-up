# 0003: Procedural placeholder rendering

**Status:** accepted for Milestones 1 and 2 (2026-11-24)

The world is drawn with Godot's 2D draw calls (`CFWorldView`). Tiles are drawn once per chunk node and cached by the engine. Glows go on an additive-blend layer, and the sky is a screen-space CanvasLayer. This keeps the visual direction (dusk Verdant Reach, amber Sunstone, violet Guile) testable without art assets.

Replace with a TileMapLayer, an atlas and animated sprites (AnimatedSprite2D or skeletal) once the art direction is approved. `CFWorldView` is the only file that needs to change, because rules and networking never touch it.
