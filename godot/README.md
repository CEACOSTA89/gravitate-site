# Protect or Destroy — Godot version (work in progress)

The game is being rebuilt in Godot 4.7 (GDScript, Compatibility renderer so it runs in browsers).
This branch (`godot`) holds the work; the live game on `main` is untouched until this is ready.

- `game/` — the Godot project. Starts with the Protect or Destroy preload (theme) scene.
- Export for the web (single-threaded, so it runs on ordinary hosting and iPhones):
  `godot --headless --path game --export-release "Web" ../build/web/index.html`
