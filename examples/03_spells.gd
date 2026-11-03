## Casting SRD spells: slot spending, saves vs attacks, upcasting, cantrip scaling,
## and area targeting through AoEResolver.
extends RefCounted

const TITLE := "3. Spells"

func run(log: ExampleLog, srd: SRDContent) -> void:
	var wizard := srd.make_character("Vex", "wizard", 5, [8, 14, 14, 16, 12, 10], "quarterstaff")
	var casting := srd.spellcasting_ability("wizard") as SRD.Ability
	var resolver := SpellResolver.new()

	log.heading("Fire Bolt (cantrip attack, scales with character level)")
	var fire_bolt := srd.make_spell("fire-bolt", casting)
	log.line("%dd%d at level 5, spell attack %+d" % [fire_bolt.base_damage_dice(5),
		fire_bolt.damage_die_sides, fire_bolt.spell_attack_bonus(wizard.stats)])
	var target := srd.make_monster("ogre")
	var ev: Dictionary = resolver.cast(wizard, fire_bolt, [target])[0]
	log.line("vs %s: %s" % [target.name, ev])

	log.heading("Fireball (3rd-level save, 20 ft sphere)")
	var fireball := srd.make_spell("fireball", casting)
	log.line("DC %d DEX save, %dd%d %s, half on save" % [fireball.spell_save_dc(wizard.stats),
		fireball.damage_die_count, fireball.damage_die_sides,
		SRD.DamageType.keys()[fireball.damage_type].to_lower()])
	var goblins := [srd.make_monster("goblin-warrior", 1), srd.make_monster("goblin-warrior", 2),
		srd.make_monster("goblin-warrior", 3)]
	var positions := { goblins[0]: Vector2(0, 0), goblins[1]: Vector2(10, 5), goblins[2]: Vector2(40, 0) }

	# The game supplies geometry; the addon supplies rules.
	var aoe := AoEResolver.new()
	aoe.targets_in_shape = func(_shape, ab: AbilityData, all: Array) -> Array:
		return all.filter(func(c): return positions[c].distance_to(Vector2.ZERO) <= ab.area_size)
	var caught := aoe.resolve(wizard, fireball, goblins)
	log.line("Centered on Goblin 1: %d of 3 in the blast" % caught.size())
	log.check(caught.size() == 2, "goblin 40 ft away is outside a 20 ft radius")

	log.check(wizard.energy_slots.use_slot(3), "spend a 3rd-level slot")
	for e in resolver.cast(wizard, fireball, caught, 3):
		log.line("  %s" % e)
	log.line("3rd-level slots left: %d" % wizard.energy_slots.slots_remaining_at(3))

	log.heading("Upcasting")
	log.line("Fireball at 5th level: %dd6" % fireball.upcasted_damage_dice(5))
	log.check(fireball.upcasted_damage_dice(5) == 10, "+1d6 per slot level above 3rd")

	log.heading("Pack coverage flags")
	var mm := srd.make_spell("magic-missile", casting)
	log.line("Magic Missile tags %s — darts aren't modeled by AbilityData yet" % [mm.tags])
	log.line("Wizard cantrips with class data: %s" % [srd.class_spell_slugs("wizard", 0)])
