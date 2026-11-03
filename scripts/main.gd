## Demo shell: pick an example, read its output. Each example is plain code in
## res://examples/ — this scene only presents them.
extends Control

var _srd: SRDContent
var _output: RichTextLabel

func _ready() -> void:
	_srd = SRDContent.new()

	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var menu := VBoxContainer.new()
	menu.custom_minimum_size.x = 260
	split.add_child(menu)
	var title := Label.new()
	title.text = "godot-dnd — SRD 5.2.1 reference"
	menu.add_child(title)
	for script in Examples.ALL:
		var b := Button.new()
		b.text = script.TITLE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(_show.bind(script))
		menu.add_child(b)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu.add_child(spacer)
	var credit := Label.new()
	credit.text = "Portions from the System Reference Document 5.2.1\n© 2025 Wizards of the Coast LLC, CC-BY-4.0"
	credit.add_theme_font_size_override("font_size", 11)
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD
	menu.add_child(credit)

	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.scroll_following = false
	_output.selection_enabled = true
	_output.add_theme_font_override("normal_font", _mono())
	_output.add_theme_font_override("bold_font", _mono())
	split.add_child(_output)

	_show(Examples.ALL[0])

func _show(script: Script) -> void:
	_output.text = Examples.run(script, _srd).bbcode()
	_output.scroll_to_line(0)

func _mono() -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["monospace"])
	return f
