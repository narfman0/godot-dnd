## A full turn-based fight: SRD party vs SRD monsters on a grid, every turn AI-planned.
## See turn_based_encounter.gd for the loop itself.
extends RefCounted

const TITLE := "4. Turn-based encounter"

func run(log: ExampleLog, srd: SRDContent) -> void:
	seed(5)  # Dice uses the global RNG; seed it for a repeatable fight
	var enc := TurnBasedEncounter.new()
	enc.event.connect(log.line)

	enc.add(srd.make_character("Rynn", "fighter", 3, [16, 12, 14, 8, 12, 10],
		"longsword", "chain-mail", true), Vector2i(0, 0), true)
	enc.add(srd.make_character("Kael", "rogue", 3, [8, 16, 14, 12, 10, 12],
		"rapier", "leather-armor"), Vector2i(0, 2), true, CombatAI.Profile.SKIRMISHER)
	enc.add(srd.make_character("Sova", "cleric", 3, [14, 10, 14, 10, 16, 12],
		"quarterstaff", "chain-shirt", true), Vector2i(-1, 1), true)

	enc.add(srd.make_monster("goblin", 1), Vector2i(8, 0), false, CombatAI.Profile.SKIRMISHER)
	enc.add(srd.make_monster("goblin", 2), Vector2i(8, 2), false, CombatAI.Profile.SKIRMISHER)
	enc.add(srd.make_monster("hobgoblin", 1), Vector2i(9, 1), false)
	enc.add(srd.make_monster("wolf", 1), Vector2i(7, 4), false)

	log.heading("Party (L3) vs 2 goblins, a hobgoblin, and a wolf")
	var winner := enc.run()
	log.heading("Result: %s after %d rounds" % [winner, enc.round_number])
	for c in enc.party + enc.enemies:
		log.line("%-12s %3d/%-3d %s" % [c.name, c.current_hp, c.stats.max_hp,
			"dead" if c.is_dead else ("down" if c.is_down else "")])
	log.check(winner != "draw", "encounter resolves within max_rounds")
