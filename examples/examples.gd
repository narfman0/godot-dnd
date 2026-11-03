## Registry of examples, shared by the demo scene and the headless runner.
class_name Examples
extends RefCounted

const ALL: Array[Script] = [
	preload("res://examples/01_content_pack.gd"),
	preload("res://examples/02_characters.gd"),
	preload("res://examples/03_spells.gd"),
	preload("res://examples/04_turn_based.gd"),
	preload("res://examples/05_balance.gd"),
]

static func run(script: Script, srd: SRDContent, echo := false) -> ExampleLog:
	var log := ExampleLog.new()
	log.echo = echo
	script.new().run(log, srd)
	return log
