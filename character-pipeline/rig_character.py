"""Rig a Protect or Destroy giant (Ghost or Nullifier) for animation, and make a lighter version for phones.

    python rig_character.py ghost     path/to/ghost.blend     OUT_DIR
    python rig_character.py nullifier path/to/nullifier.blend OUT_DIR
    (Blender as a Python module, or: blender -b --python rig_character.py -- NAME BLEND OUT_DIR)

Reads the character's .blend (from the build_*.py scripts) and joints.json (where its shoulders, elbows, wrists,
hips, knees, ankles and neck are), then:
  1. reduces every body part to about TARGET_TRIS triangles in all (Godot makes further distance versions itself),
  2. builds a skeleton through those joints: hips, spine, neck, head, and per side upper arm, forearm, hand,
     thigh, shin, foot,
  3. binds each part to the bones: body and armour by distance to the bones, blended over a short span at
     each joint; parts that must not bend (flames, eyes, head pieces) follow one bone rigidly,
  4. leaves props off the body (Ghost's rifle-katana, Nullifier's floating orbs) as separate, unrigged objects,
  5. writes NAME_rigged.blend, NAME.glb (skinned, for Godot) and test renders of a few poses.

Coordinates: Blender, z up, the character faces -y; its left side is +x. joints.json is in the game's pose space
(x to the character's right, y up from the hips, -z forward), so Blender = (-x, z, y + hipHeight).
"""
import json
import math
import os
import sys

import bpy  # first: mathutils loads with it
import bmesh
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET_TRIS = 80000
BLEND_SPAN = 0.035        # metres: how far either side of a joint the weights blend
RIGID = {                 # part name contains -> bone it follows without bending
    'ghost': {'flames': 'head', 'eye_glow': 'head', 'head_fins': 'head', 'GHO_head': 'head', 'dark_insets': 'head'},
    'nullifier': {'flames': 'head', 'eyes': 'head', 'face': 'head', 'collar_cables': 'neck'},
}
HELD = {                  # part name contains -> it follows the hand on each side (left half to hand_L, right to hand_R)
    'ghost': {},
    'nullifier': {'cords': 'hand'},
}
PROPS = {'ghost': ['rifle'], 'nullifier': ['orbs', 'orb_corona']}


def args():
    a = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    return a[0], a[1], a[2]


def bl(j, hip):           # game pose space -> Blender
    return Vector((-j[0], j[2], j[1] + hip))


def joints_for(name):
    J = json.load(open(os.path.join(HERE, 'joints.json')))[name]
    r, hip = J['rest'], J['hipHeight']
    p = {k: bl(v, hip) for k, v in r.items()}
    # canonical L/R: the game's 'L' is the character's own left
    hips = Vector((0, 0, hip))
    sh = (p['SL'] + p['SR']) / 2
    chest = hips.lerp(sh, 0.62)
    top = p['neck'] + Vector((0, 0, 0.36 * (J['height'] / 2.0)))
    fd = Vector((-J['footDir'][0], J['footDir'][2], J['footDir'][1])).normalized()
    out = {'hips': (hips, hips + Vector((0, 0, 0.12))), 'spine': (hips + Vector((0, 0, 0.12)), chest),
           'chest': (chest, sh), 'neck': (sh, p['neck']), 'head': (p['neck'], top)}
    for s in 'LR':
        out['upper_arm_' + s] = (p['S' + s], p['E' + s])
        out['forearm_' + s] = (p['E' + s], p['W' + s])
        out['hand_' + s] = (p['W' + s], p['W' + s] + (p['fist' + s] - p['W' + s]) * 1.6)
        out['thigh_' + s] = (p['H' + s], p['K' + s])
        out['shin_' + s] = (p['K' + s], p['A' + s])
        out['foot_' + s] = (p['A' + s], p['A' + s] + fd * 0.17)
    return out


PARENT = {'hips': None, 'spine': 'hips', 'chest': 'spine', 'neck': 'chest', 'head': 'neck',
          'upper_arm_L': 'chest', 'forearm_L': 'upper_arm_L', 'hand_L': 'forearm_L',
          'upper_arm_R': 'chest', 'forearm_R': 'upper_arm_R', 'hand_R': 'forearm_R',
          'thigh_L': 'hips', 'shin_L': 'thigh_L', 'foot_L': 'shin_L',
          'thigh_R': 'hips', 'shin_R': 'thigh_R', 'foot_R': 'shin_R'}


def ctx(ob, obs=None):
    obs = obs or [ob]
    return bpy.context.temp_override(active_object=ob, object=ob, selected_objects=obs, selected_editable_objects=obs)


def tris_of(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


SMOOTH = ['_body', 'leg_armor', 'NUL_plates', 'NUL_trim']   # continuous surfaces: bend smoothly at the joints


def islands(ob):
    """The separate pieces of a mesh (vertex index arrays), found by following its edges."""
    n = len(ob.data.vertices)
    parent = np.arange(n)

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for e in ob.data.edges:
        a, b = find(e.vertices[0]), find(e.vertices[1])
        if a != b:
            parent[a] = b
    roots = np.array([find(i) for i in range(n)])
    order = np.argsort(roots)
    cuts = np.nonzero(np.diff(roots[order]))[0] + 1
    return np.split(order, cuts)


def seg_dist(P, a, b):
    """Distance from points P (n,3) to segment a-b."""
    ab = b - a
    t = np.clip(((P - a) @ ab) / max(ab @ ab, 1e-9), 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1)


def main():
    name, blend, out_dir = args()
    os.makedirs(out_dir, exist_ok=True)
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(blend))
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    # bake parenting into the meshes, so everything is in world space
    for o in meshes:
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
        with ctx(o):
            bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    props = [o for o in meshes if any(k in o.name for k in PROPS[name])]
    body = [o for o in meshes if o not in props]
    total = sum(tris_of(o) for o in body)
    ratio = min(1.0, TARGET_TRIS / max(total, 1))
    for o in body:
        if tris_of(o) < 3000:
            continue
        m = o.modifiers.new('reduce', 'DECIMATE')
        m.ratio = ratio
        m.use_collapse_triangulate = True
        with ctx(o):
            bpy.ops.object.modifier_apply(modifier=m.name)
    print(f'{name}: body {total} -> {sum(tris_of(o) for o in body)} triangles (ratio {ratio:.3f}); props {[o.name for o in props]}', flush=True)

    # skeleton
    J = joints_for(name)
    arm_data = bpy.data.armatures.new(name + '_rig')
    rig = bpy.data.objects.new(name.upper() + '_RIG', arm_data)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    with ctx(rig):
        bpy.ops.object.mode_set(mode='EDIT')
    for b, (h, t) in J.items():
        eb = arm_data.edit_bones.new(b)
        eb.head, eb.tail = h, t
        eb.roll = 0
    for b, p in PARENT.items():
        if p:
            arm_data.edit_bones[b].parent = arm_data.edit_bones[p]
            arm_data.edit_bones[b].use_connect = False
    with ctx(rig):
        bpy.ops.object.mode_set(mode='OBJECT')
    segs = {b: (np.array(h), np.array(t)) for b, (h, t) in J.items()}
    bones = list(segs)

    # binding
    for o in body:
        verts = np.array([v.co[:] for v in o.data.vertices])
        groups = {b: o.vertex_groups.new(name=b) for b in bones}
        rigid = next((bone for key, bone in RIGID[name].items() if key in o.name), None)
        held = next((bone for key, bone in HELD[name].items() if key in o.name), None)
        if rigid:
            groups[rigid].add(range(len(verts)), 1.0, 'REPLACE')
        elif held:                                   # follows the hand on its own side, like a held whip
            left = np.nonzero(verts[:, 0] > 0)[0].tolist()
            right = np.nonzero(verts[:, 0] <= 0)[0].tolist()
            if left:
                groups[held + '_L'].add(left, 1.0, 'REPLACE')
            if right:
                groups[held + '_R'].add(right, 1.0, 'REPLACE')
        else:
            D = np.stack([seg_dist(verts, *segs[b]) for b in bones], axis=1)     # (n, bones)
            # Armour nearer the middle than a shoulder stays with the chest, and armour above a hip joint stays
            # with the hips; otherwise raising an arm or a knee drags a sheet of torso with it.
            for s in 'LR':
                sx = abs(segs['upper_arm_' + s][0][0])
                D[:, bones.index('upper_arm_' + s)] += np.maximum(0, sx - 0.03 - np.abs(verts[:, 0])) * 4
                hz = segs['thigh_' + s][0][2]
                D[:, bones.index('thigh_' + s)] += np.maximum(0, verts[:, 2] - (hz + 0.02)) * 4
            near = D.min(axis=1, keepdims=True)
            W = np.exp(-(D - near) / BLEND_SPAN)
            W[(D - near) > 3 * BLEND_SPAN] = 0
            # Armour and trim are made of separate plates: each plate follows one bone rigidly (the one it is
            # mostly closest to), so plates never stretch. Only the continuous body underneath bends smoothly.
            if not any(k in o.name for k in SMOOTH):
                for island in islands(o):
                    if len(island) < 4:
                        continue
                    best = np.argmin(D[island].mean(axis=0))
                    W[island] = 0
                    W[island, best] = 1
            # keep the two strongest, normalised
            top2 = np.argsort(-W, axis=1)[:, :2]
            for vi in range(len(verts)):
                i0, i1 = top2[vi]
                w0, w1 = W[vi, i0], W[vi, i1]
                s = w0 + w1
                groups[bones[i0]].add([vi], w0 / s, 'REPLACE')
                if w1 / s > 0.02:
                    groups[bones[i1]].add([vi], w1 / s, 'REPLACE')
        mod = o.modifiers.new('rig', 'ARMATURE')
        mod.object = rig
        o.parent = rig
    print(f'{name}: skeleton of {len(bones)} bones; {len(body)} parts bound', flush=True)

    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, name + '_rigged.blend'))
    # skinned glTF for Godot (rig + body; props exported separately)
    bpy.ops.object.select_all(action='DESELECT')
    for o in [rig] + body:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out_dir, name + '.glb'), export_format='GLB', use_selection=True,
                              export_skins=True, export_animations=False, export_yup=True, export_image_format='AUTO')
    if props:
        bpy.ops.object.select_all(action='DESELECT')
        for o in props:
            o.select_set(True)
        bpy.ops.export_scene.gltf(filepath=os.path.join(out_dir, name + '_props.glb'), export_format='GLB',
                                  use_selection=True, export_animations=False, export_yup=True)
    if '--renders' in sys.argv:          # needs a machine that can render (a GPU or EGL)
        test_poses(name, rig, body, props, out_dir)


def test_poses(name, rig, body, props, out_dir):
    """Render a few poses (rest, jab, side kick, guard) from the front and the side, to check the binding."""
    sc = bpy.context.scene
    for o in props:
        o.hide_render = True
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.light = 'STUDIO'
    sc.display.shading.color_type = 'MATERIAL'
    sc.render.resolution_x, sc.render.resolution_y = 480, 640
    cam_data = bpy.data.cameras.new('test_cam')
    cam = bpy.data.objects.new('test_cam', cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = 3.0
    pb = rig.pose.bones

    def rot(b, axis, deg):
        pb[b].rotation_mode = 'XYZ'
        e = pb[b].rotation_euler
        setattr(e, axis, math.radians(deg))

    poses = {
        'rest': {},
        'jab': {'upper_arm_L': ('x', 80), 'forearm_L': ('x', 5), 'upper_arm_R': ('x', 60), 'forearm_R': ('x', 100)},
        'kick': {'thigh_R': ('x', 85), 'shin_R': ('x', -10), 'chest': ('x', -15)},
        'guard': {'upper_arm_L': ('x', 40), 'forearm_L': ('x', 110), 'upper_arm_R': ('x', 40), 'forearm_R': ('x', 110)},
    }
    for pose, rots in poses.items():
        for b in pb:
            b.rotation_mode = 'XYZ'
            b.rotation_euler = (0, 0, 0)
        for b, (axis, deg) in rots.items():
            rot(b, axis, deg)
        bpy.context.view_layer.update()
        for view, loc, r in (('front', (0, -6, 1.15), (math.radians(90), 0, 0)),
                             ('side', (6, 0, 1.15), (math.radians(90), 0, math.radians(90)))):
            cam.location, cam.rotation_euler = loc, r
            sc.render.filepath = os.path.join(out_dir, f'test_{name}_{pose}_{view}.png')
            bpy.ops.render.render(write_still=True)
    print(f'{name}: test renders written', flush=True)


main()
