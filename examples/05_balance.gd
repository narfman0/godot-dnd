## Encounter balancing with BattleSimulator: run many randomized fights and read win
## rates, before an encounter ever reaches a level designer.
extends RefCounted

const TITLE := "5. Balance check"

const TRIALS := 200

func run(log: ExampleLog, srd: SRDContent) -> void:
	seed(1)
	log.heading("Party of 4 (L3) — win rate over %d simulated fights" % TRIALS)
	for group in [["goblin", "goblin", "goblin", "goblin"],
			["orc", "orc", "orc"],
			["ogre"],
			["ogre", "bugbear", "bugbear"]]:
		var xp := 0
		for slug in group:
			xp += srd.monster_xp(slug)
		var wins := 0
		var rounds := 0
		for _t in TRIALS:
			var enemies := []
			for i in group.size():
				enemies.append(srd.make_monster(group[i], i + 1))
			var result := BattleSimulator.new().run(_party(srd), enemies)
			wins += int(result.party_won)
			rounds += result.rounds_elapsed
		log.line("%-28s %4d XP   win %3d%%   avg %.1f rounds" % [", ".join(group), xp,
			100 * wins / TRIALS, float(rounds) / TRIALS])
	log.line("(BattleSimulator: melee only, no positioning — a quick first filter)")

func _party(srd: SRDContent) -> Array:
	return [
		srd.make_character("Rynn", "fighter", 3, [16, 12, 14, 8, 12, 10], "longsword", "chain-mail", true),
		srd.make_character("Kael", "rogue", 3, [8, 16, 14, 12, 10, 12], "rapier", "leather-armor"),
		srd.make_character("Sova", "cleric", 3, [14, 10, 14, 10, 16, 12], "quarterstaff", "chain-shirt", true),
		srd.make_character("Bram", "barbarian", 3, [16, 14, 15, 8, 10, 10], "greatsword", "hide"),
	]
