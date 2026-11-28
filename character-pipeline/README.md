# Character pipeline

Rigs the Protect or Destroy giants (Ghost, Nullifier) for animation and makes game-ready versions.

The character source files (`.blend`, build scripts, full-detail models) and the game-ready models are **not** in
this repository, which is public. Keep the sources in your own storage; the game-ready models are uploaded to
Cloudflare (see `godot/assets-worker/`).

    python rig_character.py ghost     /path/to/ghost.blend     OUT_DIR
    python rig_character.py nullifier /path/to/nullifier.blend OUT_DIR

(Blender as a Python module: `pip install bpy numpy`; or `blender -b --python rig_character.py -- NAME BLEND OUT_DIR`.)

Writes `NAME_rigged.blend` (keep private), `NAME.glb` (skinned, about 85–90k triangles, for the game) and
`NAME_props.glb` (Ghost's rifle, Nullifier's orbs; not rigged). Upload the .glb files with
`sh godot/assets-worker/upload.sh OUT_DIR/NAME.glb models/NAME.glb`. `joints.json` holds each character's joints.
