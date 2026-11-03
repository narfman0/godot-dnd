## Querying the SRD 5.2.1 content pack: what's in it and how to look things up.
extends RefCounted

const TITLE := "1. Content pack"

func run(log: ExampleLog, srd: SRDContent) -> void:
	var pack := srd.pack
	log.heading("Pack: %s (%s)" % [pack.meta.get("name"), pack.meta.get("version")])
	for kind in ["class", "subclass", "species", "background", "feat", "spell", "monster", "condition"]:
		log.line("%-11s %d" % [kind, pack.count(kind)])
	log.line("weapons     %d" % pack.item_slugs("weapon").size())
	log.line("armor       %d" % pack.item_slugs("armor").size())

	log.heading("Rows are {kind, slug, name, data}")
	var goblin := pack.get_row("monster", "goblin")
	log.line("%s — CR %s, %d XP, AC %d" % [goblin.name, goblin.data.cr, goblin.data.xp, goblin.data.ac])

	log.heading("Spells by level, and how many carry mechanics")
	var by_level := {}
	var with_mechanics := 0
	for slug in pack.slugs("spell"):
		var lvl: int = int(pack.get_row("spell", slug).data.level)
		by_level[lvl] = by_level.get(lvl, 0) + 1
		if srd.spell_has_mechanics(slug):
			with_mechanics += 1
	for lvl in range(10):
		log.line("%s: %d" % ["cantrips" if lvl == 0 else "level %d" % lvl, by_level.get(lvl, 0)])
	log.line("%d / %d have engine activities; the rest build as 'stub' AbilityData"
		% [with_mechanics, pack.count("spell")])

	log.heading("Class features (wizard, levels 1-3)")
	for lvl in range(1, 4):
		for f in srd.class_features_at("wizard", lvl):
			log.line("L%d  %s" % [lvl, f.name])

	log.check(pack.count("class") == 12, "all 12 SRD classes present")
	log.check(pack.count("spell") > 300, "spell list loaded")
