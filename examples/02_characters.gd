## Building player characters from SRD classes: ability scores, HP, AC, proficiencies,
## leveling, and resting.
extends RefCounted

const TITLE := "2. Characters"

func run(log: ExampleLog, srd: SRDContent) -> void:
	log.heading("Ability scores")
	log.line("Standard array: %s" % [SRDAbilityScores.STANDARD_ARRAY])
	var buy := [15, 15, 15, 8, 8, 8]
	log.line("Point buy %s costs %d / %d" % [buy, SRDAbilityScores.point_buy_total(buy),
		SRDAbilityScores.POINT_BUY_BUDGET])

	log.heading("make_character: class + level + scores (STR..CHA) + gear")
	var fighter := srd.make_character("Rynn", "fighter", 1, [15, 13, 14, 8, 12, 10],
		"longsword", "chain-mail", true, ["athletics", "perception"])
	_describe(log, fighter)
	log.check(fighter.stats.max_hp == 12, "fighter L1 HP = d10 + CON")
	log.check(fighter.armor_class == 18, "chain mail + shield = AC 18")

	var wizard := srd.make_character("Vex", "wizard", 1, [8, 14, 13, 15, 12, 10],
		"quarterstaff", "", false, ["arcana", "history"])
	_describe(log, wizard)

	log.heading("Level up (average HP, new slots)")
	var wiz_class := srd.make_class("wizard")
	for _i in 4:
		var gained := SRDLevelUp.level_up(wizard.stats, wiz_class, wizard.energy_slots)
		log.line("Vex → level %d: +%d HP (max %d), slots %s" % [wizard.stats.level, gained,
			wizard.stats.max_hp, _slots(wizard.energy_slots)])
	log.check(wizard.energy_slots.slots_remaining_at(3) == 2, "level 5 wizard has two 3rd-level slots")

	log.heading("Skills and passive scores")
	log.line("Rynn Athletics %+d, passive Perception %d" % [
		SRDSkills.skill_bonus(fighter.stats, SRD.Skill.ATHLETICS),
		SRDRules.passive_check(fighter.stats, SRD.Skill.PERCEPTION)])

	log.heading("Rest")
	fighter.stats.take_damage(9)
	log.line("Rynn takes 9: %d/%d" % [fighter.current_hp, fighter.stats.max_hp])
	var healed := SRDRest.short_rest(fighter.stats, 1)
	log.line("Short rest, spend 1 hit die: +%d → %d" % [healed, fighter.current_hp])
	SRDRest.long_rest(fighter.stats)
	log.line("Long rest → %d" % fighter.current_hp)
	log.check(fighter.current_hp == fighter.stats.max_hp, "long rest restores HP")

func _describe(log: ExampleLog, c: Combatant) -> void:
	var s := c.stats
	var scores := []
	for a in 6:
		scores.append("%s %d" % [SRD.ability_abbrev(a), s.get_ability(a)])
	log.line("%s (L%d)  HP %d  AC %d  attack %+d with %s%s" % [s.character_name, s.level,
		s.max_hp, c.armor_class, c.attack_modifier(),
		c.weapon.weapon_name if c.weapon else "unarmed",
		"" if c.is_proficient_with_weapon else " (not proficient)"])
	log.line("    " + ", ".join(scores) + "   slots " + _slots(c.energy_slots))

func _slots(slots: EnergySlots) -> String:
	var parts := []
	for lvl in range(1, 10):
		if slots.slots_max[lvl - 1] > 0:
			parts.append("L%d×%d" % [lvl, slots.slots_remaining_at(lvl)])
	return "none" if parts.is_empty() else " ".join(parts)
