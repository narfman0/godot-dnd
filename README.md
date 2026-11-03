# godot-dnd

Reference shell for building SRD 5.2.1 games in Godot 4.7 on top of
[godot-srd-addon](https://github.com/narfman0/godot-srd-addon). It's not a game: it's
small, runnable examples of each part of the rules API, meant to be copied from when
starting a real project.

## Setup

```bash
git clone --recurse-submodules https://github.com/narfman0/godot-dnd.git
cd godot-dnd
godot --headless --import
godot                                            # demo scene: pick an example, read its output
godot --headless -s res://tools/run_examples.gd  # run every example; prints ALL PASS
```

`addons/srd` is a committed symlink into the `vendor/godot-srd-addon` submodule (the same
layout as Wayfarer). On Windows, enable git symlinks before cloning.

## Examples

| File | Shows |
|---|---|
| `examples/01_content_pack.gd` | Querying the pack: counts, rows, spell coverage, class features |
| `examples/02_characters.gd` | `make_character`, ability scores, level up, skills, rests |
| `examples/03_spells.gd` | Spell attacks and saves, slots, upcasting, AoE targeting |
| `examples/04_turn_based.gd` | A full grid fight: initiative, movement, AI turns, death saves |
| `examples/05_balance.gd` | Win rates for monster groups via `BattleSimulator` |
| `examples/turn_based_encounter.gd` | The reusable turn loop example 4 runs on |

The split to keep in a real game: **the addon owns the rules, the game owns space.**
`TurnBasedEncounter` answers the addon's spatial questions (`AIContext` callables,
`AoEResolver.targets_in_shape`) from a 5-ft grid. A 3D game answers them from its own
scene and navigation instead, and nothing in the addon changes.

## Gaps to know about

All of these come from the SRD pack, which is maintained in grimoire:

- Monsters: 10 of ~330. Weapons: 16 of 38.
- 214 of 310 spells are stubs (name/level/school, no mechanics) and build with the `stub`
  tag. Spells with effects `AbilityData` can't express yet (Magic Missile's darts,
  multi-part damage) carry `partial`.
- 48 spells have no `classes` list, so `class_spell_slugs` misses them.

The turn loop also leaves out opportunity attacks, cover, spellcasting during turns, and
player input.

## Exporting

Add `*.json` to the export preset's non-resource filter so the SRD pack ships.

## Attribution

Portions of this content are from the System Reference Document 5.2.1 © 2025 Wizards of
the Coast LLC, available at <https://dnd.wizards.com/resources/systems-reference-document>
under the Creative Commons Attribution 4.0 International License. Wizards of the Coast
endorsement is not implied.
