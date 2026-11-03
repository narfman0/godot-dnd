## Querying the SRD 5.2.1 content pack: what's in it and how to look things up.
extends RefCounted

const TITLE := "1. Content pack"

func run(log: ExampleLog, srd: SRDContent) -> void:
	var pack := srd.pack
	log.heading("Pack: %s (%s)" % [pack.meta.get("name"), pack.meta.get("version")])
	for kind in ["class", "spell", "monster", "weapon", "armor"]:
		log.line("%-8s %d" % [kind, pack.count(kind)])
	log.line("(extracted from the SRD 5.2.1 PDF; more sections are added as games need them)")

	log.heading("Rows are {kind, slug, name, page, data}")
	var goblin := pack.get_row("monster", "goblin-warrior")
	log.line("%s (SRD p.%d) — CR %s, %d XP, AC %d, HP %d (%s)" % [goblin.name, goblin.page,
		goblin.data.cr, goblin.data.xp, goblin.data.ac, goblin.data.hp, goblin.data.hp_dice])
	for a in goblin.data.actions:
		log.line("  %s: %s" % [a.name, a.text])

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
	log.line("%d / %d have detected damage or healing; the rest build tagged 'no_mechanics'"
		% [with_mechanics, pack.count("spell")])

	log.heading("Class core traits")
	for slug in pack.slugs("class"):
		var d: Dictionary = pack.get_row("class", slug).data
		log.line("%-9s d%-2d saves %s  %s" % [slug, d.hit_die, d.saves,
			d.spellcasting.progression + " caster" if d.has("spellcasting") else ""])

	log.check(pack.count("class") == 12, "all 12 SRD classes present")
	log.check(pack.count("spell") > 300, "spell list loaded")
