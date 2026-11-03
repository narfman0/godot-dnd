# godot-dnd: agent notes

A reference shell, not a game. It exists to show how to use `godot-srd-addon`. Real games
start as new projects that copy patterns from here.

- Rules live in the addon (`vendor/godot-srd-addon`, symlinked at `addons/srd`). Change
  rules there, with GUT tests (`godot --headless -s addons/gut/gut_cmdln.gd
  -gdir=res://tests -gexit`, run from the addon repo), then bump the submodule here.
- SRD data comes from grimoire's `content-packs/srd-5.2`. Fix data gaps there, then run
  the addon's `tools/sync_srd_pack.sh`.
- Each example is a `RefCounted` with `TITLE` and `run(log: ExampleLog, srd: SRDContent)`,
  registered in `examples/examples.gd`. Use `log.check()` so the example also works as a
  smoke test.
- Verify with `godot --headless -s res://tools/run_examples.gd` (must print ALL PASS).
  For the UI: `xvfb-run -a godot --rendering-driver vulkan -s res://tools/screenshot.gd
  -- out.png [example_index]`, and look at the result.
- Godot 4.7 gotchas: `trait` is a reserved word; inner `class` declarations must be at
  file scope; lambdas capture locals by value.
