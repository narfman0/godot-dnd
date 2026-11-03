## Reference turn-based encounter loop over the SRD addon, on a 5-ft square grid.
##
## The addon owns rules (initiative, action economy, attack/damage, death saves, AI
## decisions); this class owns everything spatial — positions, movement, range — which is
## the split a real game keeps when the grid becomes a 3D scene with NavigationServer.
##
## Not modeled here (left for the game layer): opportunity attacks, cover, spells in
## the turn loop, player input. Every combatant is AI-driven so the loop can run headless.
class_name TurnBasedEncounter
extends RefCounted

signal turn_started(actor: Combatant, round_number: int)
signal event(text: String)

const SQUARE_FT := 5

var party: Array = []    ## Array[Combatant]
var enemies: Array = []  ## Array[Combatant]
var cells := {}          ## Combatant -> Vector2i grid square
var profiles := {}       ## Combatant -> CombatAI.Profile
var round_number := 0
var max_rounds := 30

var _order: Array = []   ## Array[Combatant], initiative order

func add(c: Combatant, cell: Vector2i, is_party: bool,
		profile: CombatAI.Profile = CombatAI.Profile.AGGRESSIVE) -> void:
	(party if is_party else enemies).append(c)
	cells[c] = cell
	profiles[c] = profile

## Run to completion. Returns "party", "enemies", or "draw".
func run() -> String:
	_roll_initiative()
	while round_number < max_rounds:
		round_number += 1
		event.emit("— Round %d —" % round_number)
		for actor in _order:
			if _side_defeated(party) or _side_defeated(enemies):
				break
			take_turn(actor)
		if _side_defeated(enemies):
			return "party"
		if _side_defeated(party):
			return "enemies"
	return "draw"

func take_turn(actor: Combatant) -> void:
	if actor.is_dead or actor.death_saves.is_stable:
		return
	if actor.is_down:
		var roll := actor.death_saves.roll()
		if roll == 20:
			# Natural 20: regain 1 HP and act normally from next turn
			actor.stats.current_hp = 1
			actor.death_saves.revive()
			event.emit("%s rolls a natural 20 and rallies with 1 HP!" % actor.name)
			return
		event.emit("%s death save: %d (%d✓ %d✗)%s" % [actor.name, roll,
			actor.death_saves.successes, actor.death_saves.failures,
			" — dies" if actor.is_dead else (" — stable" if actor.death_saves.is_stable else "")])
		return
	if not actor.can_act():
		return

	turn_started.emit(actor, round_number)
	actor.action_economy.reset_turn()
	var plan := CombatAI.plan_turn(_context(actor), profiles[actor])

	# Actions that change how you move (Dash, Disengage, Dodge) resolve before moving
	match plan.action:
		TurnPlan.ActionChoice.DASH:
			actor.action_economy.dash()
		TurnPlan.ActionChoice.DODGE, TurnPlan.ActionChoice.DISENGAGE, TurnPlan.ActionChoice.HELP:
			actor.action_economy.use_action()
			event.emit("%s takes the %s action" % [actor.name,
				TurnPlan.ActionChoice.keys()[plan.action].capitalize()])
	match plan.move_intent:
		TurnPlan.MoveIntent.CLOSE_TO_TARGET:
			_move_toward(actor, plan.move_target)
		TurnPlan.MoveIntent.RETREAT:
			_move_away(actor, plan.move_target)

	if plan.action == TurnPlan.ActionChoice.ATTACK and plan.action_target != null \
			and _in_reach(actor, plan.action_target) and actor.action_economy.use_action():
		attack(actor, plan.action_target)

## One weapon attack: d20 + modifier vs AC, nat 20 crits, nat 1 misses.
func attack(attacker: Combatant, target: Combatant) -> void:
	var d20 := Dice.roll_d20()
	var total := d20 + attacker.attack_modifier()
	var crit := SRDRules.is_critical_hit(d20)
	var hit := crit or (not SRDRules.is_critical_miss(d20) and total >= target.armor_class)
	var weapon_name := attacker.weapon.weapon_name if attacker.weapon else "unarmed strike"
	if not hit:
		event.emit("%s → %s with %s: %d vs AC %d, miss" % [attacker.name, target.name,
			weapon_name, total, target.armor_class])
		return
	var was_down := target.is_down
	var dmg := attacker.roll_damage(crit)
	var dealt := target.take_damage(dmg,
		attacker.weapon.damage_type if attacker.weapon else SRD.DamageType.BLUDGEONING, crit)
	if was_down:
		target.death_saves.on_damage_taken(crit)  # damage at 0 HP costs death saves
	event.emit("%s → %s with %s: %d vs AC %d, %s%d damage (%d/%d)%s" % [attacker.name,
		target.name, weapon_name, total, target.armor_class, "CRIT " if crit else "", dealt,
		target.current_hp, target.stats.max_hp, _status(target)])

func distance_ft(a: Combatant, b: Combatant) -> int:
	# SRD grid rule: diagonals cost 5 ft, so distance is the larger axis delta
	var d: Vector2i = (cells[a] - cells[b]).abs()
	return maxi(d.x, d.y) * SQUARE_FT

# ── AI wiring: the addon asks spatial questions through these callables ──────

func _context(actor: Combatant) -> AIContext:
	var ctx := AIContext.new()
	ctx.actor = actor
	var mine := party if actor in party else enemies
	ctx.allies = mine.filter(func(c): return c != actor and c.is_active)
	ctx.enemies = (enemies if mine == party else party).filter(func(c): return c.is_active)
	ctx.is_in_melee_range = func(a, b): return _in_reach(a, b)
	ctx.can_reach_in_one_move = func(a, b):
		return distance_ft(a, b) - _reach(a) <= a.action_economy.movement_remaining
	ctx.distance_feet = distance_ft
	ctx.cover_between = func(_a, _b): return SRD.Cover.NONE
	return ctx

func _reach(c: Combatant) -> int:
	return c.weapon.range_normal if c.weapon else SQUARE_FT

func _in_reach(a: Combatant, b: Combatant) -> bool:
	return distance_ft(a, b) <= _reach(a)

func _move_toward(actor: Combatant, target: Combatant) -> void:
	var start: Vector2i = cells[actor]
	while not _in_reach(actor, target) and actor.action_economy.spend_movement(SQUARE_FT):
		var step: Vector2i = (cells[target] - cells[actor]).sign()
		var next: Vector2i = cells[actor] + step
		if _occupied(next):
			break
		cells[actor] = next
	if cells[actor] != start:
		event.emit("%s moves %d ft toward %s" % [actor.name,
			maxi(absi(cells[actor].x - start.x), absi(cells[actor].y - start.y)) * SQUARE_FT, target.name])

func _move_away(actor: Combatant, threat: Combatant) -> void:
	while actor.action_economy.spend_movement(SQUARE_FT):
		var next: Vector2i = cells[actor] + (cells[actor] - cells[threat]).sign()
		if _occupied(next):
			break
		cells[actor] = next
	event.emit("%s falls back" % actor.name)

func _occupied(cell: Vector2i) -> bool:
	for c in cells:
		if cells[c] == cell and not c.is_dead:
			return true
	return false

func _roll_initiative() -> void:
	var rolls := {}
	for c in party + enemies:
		rolls[c] = Dice.roll_d20() + c.stats.ability_modifier(SRD.Ability.DEXTERITY)
	_order = party + enemies
	_order.sort_custom(func(a, b): return rolls[a] > rolls[b] if rolls[a] != rolls[b] \
		else a.stats.dexterity > b.stats.dexterity)
	event.emit("Initiative: " + ", ".join(_order.map(func(c): return "%s %d" % [c.name, rolls[c]])))

func _side_defeated(side: Array) -> bool:
	return side.all(func(c): return not c.can_act())

func _status(c: Combatant) -> String:
	if c.is_dead:
		return " — dies"
	if c.is_down:
		return " — falls unconscious"
	return ""
