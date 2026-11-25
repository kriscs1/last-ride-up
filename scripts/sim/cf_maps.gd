class_name CFMaps
## The map list. Every map is 150 x 64 tiles, uses the same camp layout and the same mechanisms,
## and is proven reachable by tools/check_map.py.

const IDS := ["verdant", "mines", "marsh"]


static func data(map_id: String) -> Dictionary:
	match map_id:
		"mines":
			return {"id": CFMapMines.ID, "name": CFMapMines.NAME, "blurb": CFMapMines.BLURB, "map": CFMapMines.MAP, "areas": CFMapMines.AREAS, "theme": CFMapMines.THEME, "decor": CFMapMines.DECOR}
		"marsh":
			return {"id": CFMapMarsh.ID, "name": CFMapMarsh.NAME, "blurb": CFMapMarsh.BLURB, "map": CFMapMarsh.MAP, "areas": CFMapMarsh.AREAS, "theme": CFMapMarsh.THEME, "decor": CFMapMarsh.DECOR}
		_:
			return {"id": CFMapVerdant.ID, "name": CFMapVerdant.NAME, "blurb": CFMapVerdant.BLURB, "map": CFMapVerdant.MAP, "areas": CFMapVerdant.AREAS, "theme": CFMapVerdant.THEME, "decor": CFMapVerdant.DECOR}


static func is_valid(map_id: String) -> bool:
	return IDS.has(map_id)


static func pick(choice: String) -> String:
	## "random" (or anything unknown) picks one of the maps.
	if is_valid(choice):
		return choice
	return IDS[randi() % IDS.size()]
