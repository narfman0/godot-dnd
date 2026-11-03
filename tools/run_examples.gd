## Headless runner: executes every example and exits nonzero if any check fails.
##   godot --headless -s res://tools/run_examples.gd
extends SceneTree

func _init() -> void:
	var srd := SRDContent.new()
	var failed := 0
	for script in Examples.ALL:
		print("\n######## %s ########" % script.TITLE)
		var log := Examples.run(script, srd, true)
		failed += log.failures.size()
	print("\n%s" % ("ALL PASS" if failed == 0 else "%d CHECK(S) FAILED" % failed))
	quit(0 if failed == 0 else 1)
