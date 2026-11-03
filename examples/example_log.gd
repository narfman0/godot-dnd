## Output sink shared by the examples: collects lines for the demo scene or the console,
## and records failed checks so each example doubles as a smoke test.
class_name ExampleLog
extends RefCounted

var lines: PackedStringArray = []
var failures: PackedStringArray = []
var echo := false  ## print each line as it's written (headless runner)

func heading(text: String) -> void:
	_add("\n[b]== %s ==[/b]" % text, "\n== %s ==" % text)

func line(text: String) -> void:
	_add(text, text)

## Assert-like check that reports instead of crashing.
func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		_add("[color=red]CHECK FAILED: %s[/color]" % message, "CHECK FAILED: " + message)

func bbcode() -> String:
	return "\n".join(lines)

func _add(rich: String, plain: String) -> void:
	lines.append(rich)
	if echo:
		print(plain)
