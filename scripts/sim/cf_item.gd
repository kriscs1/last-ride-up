class_name CFItem
extends RefCounted

var id := 0
var kind := "coin"   # coin (shard), bag (cluster), chest (crate), relic (Sunstone), cache, idol (Heartstone)
var x := 0.0
var y := 0.0
var value := 0
var max_value := 0
var gone := false
var opened := false
var empty := false
var dropped := false
var ph := 0.0
var carriers: Array = []          # two player ids while the Heartstone is carried
var waiting_id := ""              # first carrier waiting for a partner
var waiting_until := 0.0
var fake := false                 # fool's stone from a tainted vein: weighs the same, worth nothing
var born := -10.0                 # match time it burst out of a vein (for the pop animation)
var from := Vector2.ZERO          # where it burst from
var spilled_by := ""              # server only: who spilled it; they must step away before taking it back
