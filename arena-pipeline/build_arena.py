"""Step 2 of the arena pipeline (runs in Blender): buildings.json -> the arena the game loads.

    blender --background --python build_arena.py -- buildings.json OUT_DIR [--blend arena.blend]
    (or, with Blender as a Python module:  python build_arena.py buildings.json OUT_DIR)

Writes into OUT_DIR:
  city.glb              every building, facade textured. Buildings the giants can reach are separate nodes
                        named by their key; the rest are merged by material.
  collapse/<key>.glb    each reachable building cut into chunks (node c0, c1, ...), at rest.
  collapse/<key>.bin    the baked collapse of those chunks, two takes: hit by a giant moving uptown, and moving
                        downtown. Int16 per chunk per frame: x, y, z in centimetres from the building's base
                        centre, then a quaternion x, y, z, w scaled by 32767.
  arena.json            what the game needs: footprints and heights (for hits), keys, chunk counts, frames.

Texture coordinates (so real facades can replace the placeholders):
  UVMap  (TEXCOORD_0)  tiling: u = metres along the building's outline / 12, v = metres up / 14.
                       The placeholder facade images each cover 12 m x 14 m (4 bays, 4 floors).
  Atlas  (TEXCOORD_1)  one image per building: u = 0..1 once around the outline (starting at its first corner,
                       counter-clockwise seen from above), v = 0..1 from the ground to the roof.
Scene coordinates: metres, y up, +z uptown along the avenues, +x the west side (the same as the game's).
Blender is z up: Blender (x, y, z) = scene (x, -z, y).
"""
import json
import math
import os
import random
import struct
import sys

import bpy  # first: bmesh and mathutils load with it
import bmesh
from mathutils import Matrix, Vector
from shapely.geometry import LineString, MultiPoint, Point, Polygon
from shapely.ops import voronoi_diagram

HERE = os.path.dirname(os.path.abspath(__file__))
TILE_W, TILE_H = 12.0, 14.0
FPS_SIM, FPS_OUT, SECONDS = 30, 15, 6.5
GIANT_SPEED = 18.0                  # m/s: how fast the knocked giant slams into the building
FACADES = ['facade_brick', 'facade_limestone', 'facade_beige', 'facade_modern']


def args():
    a = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    blend = None
    if '--blend' in a:
        i = a.index('--blend'); blend = a[i + 1]; a = a[:i] + a[i + 2:]
    return a[0], a[1], blend


def to_bl(x, y, z):          # scene -> Blender
    return Vector((x, -z, y))


# ---------- materials ----------
def material(name, image_path, rough=0.85):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.inputs['Roughness'].default_value = rough
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(image_path, check_existing=True)
    uv = nt.nodes.new('ShaderNodeUVMap')
    uv.uv_map = 'UVMap'
    nt.links.new(uv.outputs['UV'], tex.inputs['Vector'])
    nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    nt.links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])
    return m


def materials(tex_dir):
    mats = {n: material(n, os.path.join(tex_dir, n + '.jpg')) for n in FACADES + ['facade_landmark']}
    mats['roof'] = material('roof', os.path.join(tex_dir, 'roof.jpg'), 0.95)
    mats['concrete'] = material('concrete', os.path.join(tex_dir, 'concrete.jpg'), 0.95)
    return mats


# ---------- geometry ----------
class Outline:
    """A building's outline, for mapping points on it to the distance around it (the facade's u)."""
    def __init__(self, pts):
        self.ring = LineString(list(pts) + [pts[0]])
        self.length = self.ring.length

    def u(self, x, z):
        return self.ring.project(Point(x, z))


def prism(bm, uv0, uv1, cell, z0, z1, b, outline, slot, centre):
    """Add a prism (a footprint piece extruded from z0 to z1) to bm. Faces on the building's outline get the
    facade (slot 0); top at the roof gets the roof (slot 1); cut faces get concrete (slot 2)."""
    pts = list(cell.exterior.coords)[:-1]
    if Polygon(pts).exterior.is_ccw is False:
        pts.reverse()
    cx, cz = centre
    H = b['height']
    lo = [bm.verts.new(to_bl(x - cx, z0, z - cz)) for x, z in pts]
    hi = [bm.verts.new(to_bl(x - cx, z1, z - cz)) for x, z in pts]
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        (xa, za), (xb, zb) = pts[i], pts[j]
        f = bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
        mid = Point((xa + xb) / 2, (za + zb) / 2)
        on_outline = outline.ring.distance(mid) < 0.05
        f.material_index = 0 if on_outline else 2
        if on_outline:
            ua, ub = outline.u(xa, za), outline.u(xb, zb)
            if ub < ua - outline.length / 2:
                ub += outline.length
            if ua < ub - outline.length / 2:
                ua += outline.length
            us = [ua, ub, ub, ua]
        else:
            seg = math.hypot(xb - xa, zb - za)
            us = [0, seg, seg, 0]
        vs = [z0, z0, z1, z1]
        for loop, u, v in zip(f.loops, us, vs):
            loop[uv0].uv = (u / TILE_W, v / TILE_H)
            loop[uv1].uv = ((u / outline.length) if on_outline else 0.0, v / H)
    top = bm.faces.new(hi)
    top.material_index = 1 if z1 >= H - 0.01 else 2
    bot = bm.faces.new(list(reversed(lo)))
    bot.material_index = 2
    for f in (top, bot):
        for loop in f.loops:
            x, z = loop.vert.co.x + cx, -loop.vert.co.y + cz
            loop[uv0].uv = (x / TILE_W, z / TILE_W)
            loop[uv1].uv = (0.0, 1.0)


def mesh_object(name, cells_bands, b, mats, centre, facade):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    uv0 = bm.loops.layers.uv.new('UVMap')
    uv1 = bm.loops.layers.uv.new('Atlas')
    outline = Outline(b['pts'])
    for cell, z0, z1 in cells_bands:
        prism(bm, uv0, uv1, cell, z0, z1, b, outline, 0, centre)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    for m in (mats[facade], mats['roof'], mats['concrete']):
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def facade_for(b):
    if b['landmark']:
        return 'facade_landmark'
    if b['height'] > 70:
        return 'facade_modern'
    return FACADES[int(b['bin']) % 3]


def centre_of(b):
    c = Polygon(b['pts']).centroid
    return (c.x, c.y)


# ---------- fracture ----------
def fracture(b):
    """Cut the footprint into Voronoi cells and the height into floor bands. Deterministic per building."""
    rnd = random.Random(b['key'])
    poly = Polygon(b['pts'])
    if b['landmark']:
        n_cells, n_bands = 12, 12
    else:
        n_cells = max(4, min(9, round(poly.area / 180)))
        n_bands = max(3, min(8, round(b['height'] / 10)))
    minx, miny, maxx, maxy = poly.bounds
    seeds = []
    while len(seeds) < n_cells:
        p = Point(rnd.uniform(minx, maxx), rnd.uniform(miny, maxy))
        if poly.contains(p):
            seeds.append(p)
    cells = []
    for region in voronoi_diagram(MultiPoint(seeds), envelope=poly.buffer(50)).geoms:
        piece = region.intersection(poly)
        for g in (piece.geoms if hasattr(piece, 'geoms') else [piece]):
            if g.geom_type == 'Polygon' and g.area > 1.0:
                cells.append(g.simplify(0.05))
    cuts = [0.0]
    step = b['height'] / n_bands
    for i in range(1, n_bands):
        cuts.append(i * step + rnd.uniform(-0.25, 0.25) * step)
    cuts.append(b['height'])
    return [(c, cuts[i], cuts[i + 1]) for c in cells for i in range(n_bands)]


# ---------- collapse simulation ----------
def reset_scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for me in list(bpy.data.meshes):
        if me.users == 0:
            bpy.data.meshes.remove(me)
    sc = bpy.context.scene
    if sc.rigidbody_world:
        bpy.ops.rigidbody.world_remove()


def add_body(ob, kind='ACTIVE', mass=1.0):
    with bpy.context.temp_override(active_object=ob, object=ob, selected_objects=[ob], selected_editable_objects=[ob]):
        bpy.ops.rigidbody.object_add()
    ob.rigid_body.type = kind
    ob.rigid_body.mass = mass
    ob.rigid_body.friction = 0.7
    ob.rigid_body.restitution = 0.05
    ob.rigid_body.collision_shape = 'CONVEX_HULL'
    ob.rigid_body.linear_damping = 0.08
    ob.rigid_body.angular_damping = 0.15


def simulate(b, pieces, direction, rail, mats):
    """Collapse of one building hit by a giant moving uptown (+1) or downtown (-1). Returns frames of
    [(x, y, z, qx, qy, qz, qw) per chunk] in scene coordinates, relative to the building's base centre."""
    reset_scene()
    sc = bpy.context.scene
    sc.render.fps = FPS_SIM
    sc.frame_start, sc.frame_end = 1, int(SECONDS * FPS_SIM)
    bpy.ops.rigidbody.world_add()
    rw = sc.rigidbody_world
    rw.substeps_per_frame, rw.solver_iterations = 10, 20
    rw.point_cache.frame_start, rw.point_cache.frame_end = 1, sc.frame_end
    centre = centre_of(b)
    bpy.ops.mesh.primitive_plane_add(size=2000, location=(0, 0, 0))
    add_body(bpy.context.object, 'PASSIVE')
    chunks = []
    for i, (cell, z0, z1) in enumerate(pieces):
        ob = mesh_object('c%d' % i, [(cell, z0, z1)], b, mats, centre, facade_for(b))
        with bpy.context.temp_override(active_object=ob, object=ob, selected_objects=[ob], selected_editable_objects=[ob]):
            bpy.ops.object.origin_set(type='ORIGIN_CENTER_OF_MASS', center='MEDIAN')
        add_body(ob, 'ACTIVE', max(1.0, cell.area * (z1 - z0) * 0.25))
        chunks.append(ob)
    # The giant: a kinematic block the width of a giant's body, driven through the building along the avenue.
    # It hits the lower floors across the building's whole width (the upper floors then drop onto the wreckage)
    # and drives through at GIANT_SPEED.
    giant = rail['giant']
    poly = Polygon(b['pts'])
    minx, minz, maxx, maxz = poly.bounds
    bx = (minx + maxx) / 2 - centre[0]
    width = max(0.34 * giant, (maxx - minx) + 6)        # the whole width: every lower floor is knocked out
    zmin, zmax = minz - centre[1], maxz - centre[1]
    hit_h = min(0.55 * b['height'], 0.64 * giant)
    depth = 0.34 * giant
    start_z = (zmin - depth / 2 - 1) if direction > 0 else (zmax + depth / 2 + 1)
    travel = (zmax - zmin) + depth / 2 + 6      # all the way through the lower floors: nothing left holding the top up
    end_z = start_z + direction * travel
    bpy.ops.mesh.primitive_cube_add(size=1, location=to_bl(bx, hit_h / 2, start_z))
    pusher = bpy.context.object
    pusher.scale = (width, depth, hit_h)                        # x across, y along (Blender), z up
    add_body(pusher, 'ACTIVE')
    pusher.rigid_body.kinematic = True
    pusher.rigid_body.collision_shape = 'BOX'
    pusher.keyframe_insert('location', frame=1)
    pusher.location = to_bl(bx, hit_h / 2, end_z)
    pusher.keyframe_insert('location', frame=1 + max(3, round(travel / GIANT_SPEED * FPS_SIM)))
    for fc in (pusher.animation_data.action.fcurves if hasattr(pusher.animation_data.action, 'fcurves') else []):
        for k in fc.keyframe_points:
            k.interpolation = 'LINEAR'
    # scene (x, y, z) = C * Blender (x, y, z)
    C = Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0)))
    Ci = C.inverted()
    frames = []
    step = FPS_SIM // FPS_OUT
    for f in range(1, sc.frame_end + 1):
        sc.frame_set(f)
        if (f - 1) % step:
            continue
        row = []
        for ob in chunks:
            mw = ob.matrix_world
            t = C @ mw.translation
            q = (C @ mw.to_3x3() @ Ci).to_quaternion()
            row.append((t.x, t.y, t.z, q.x, q.y, q.z, q.w))
        frames.append(row)
    return frames


def write_bin(path, takes):
    with open(path, 'wb') as fh:
        for frames in takes:
            for row in frames:
                for x, y, z, qx, qy, qz, qw in row:
                    fh.write(struct.pack('<7h', *(max(-32767, min(32767, round(v))) for v in
                                                  (x * 100, y * 100, z * 100, qx * 32767, qy * 32767, qz * 32767, qw * 32767))))


def export(path, objects):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in objects:
        ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', use_selection=True, export_texcoords=True,
                              export_normals=True, export_materials='EXPORT', export_image_format='JPEG',
                              export_jpeg_quality=82, export_animations=False, export_yup=True)


def join(objects, name):
    if not objects:
        return None
    with bpy.context.temp_override(active_object=objects[0], object=objects[0], selected_objects=objects,
                                   selected_editable_objects=objects):
        bpy.ops.object.join()
    objects[0].name = name
    return objects[0]


def main():
    src, out_dir, blend = args()
    data = json.load(open(src))
    os.makedirs(os.path.join(out_dir, 'collapse'), exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mats = materials(os.path.join(HERE, 'textures'))
    rail = data['rail']
    manifest = {'arena': data['arena'], 'source': data['source'], 'rail': rail, 'fps': FPS_OUT,
                'texture': {'tileW': TILE_W, 'tileH': TILE_H}, 'buildings': []}

    # Collapses first (each simulation starts from an empty scene).
    for b in data['buildings']:
        entry = {'key': b['key'], 'height': b['height'], 'pts': b['pts'], 'landmark': b['landmark']}
        if b['hittable']:
            pieces = fracture(b)
            takes = [simulate(b, pieces, d, rail, mats) for d in (+1, -1)]
            write_bin(os.path.join(out_dir, 'collapse', b['key'] + '.bin'), takes)
            # chunks at rest, origin at each chunk's centre of mass, placed relative to the base centre
            reset_scene()
            centre = centre_of(b)
            parts = []
            for i, (cell, z0, z1) in enumerate(pieces):
                ob = mesh_object('c%d' % i, [(cell, z0, z1)], b, mats, centre, facade_for(b))
                with bpy.context.temp_override(active_object=ob, object=ob, selected_objects=[ob], selected_editable_objects=[ob]):
                    bpy.ops.object.origin_set(type='ORIGIN_CENTER_OF_MASS', center='MEDIAN')
                parts.append(ob)
            export(os.path.join(out_dir, 'collapse', b['key'] + '.glb'), parts)
            entry.update({'chunks': len(pieces), 'frames': len(takes[0]), 'centre': [round(v, 2) for v in centre_of(b)]})
            print('baked', b['key'], b['height'], 'm,', len(pieces), 'chunks', flush=True)
        manifest['buildings'].append(entry)

    # The standing city.
    reset_scene()
    standing, by_facade = [], {}
    for b in data['buildings']:
        centre = centre_of(b)
        ob = mesh_object(b['key'], [(Polygon(b['pts']), 0.0, b['height'])], b, mats, centre, facade_for(b))
        ob.location = to_bl(centre[0], 0, centre[1])
        if b['hittable']:
            standing.append(ob)
        else:
            by_facade.setdefault(facade_for(b), []).append(ob)
    for name, obs in by_facade.items():
        standing.append(join(obs, 'city_' + name))
    export(os.path.join(out_dir, 'city.glb'), standing)
    json.dump(manifest, open(os.path.join(out_dir, 'arena.json'), 'w'), separators=(',', ':'))
    if blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend))
    print('done:', len(manifest['buildings']), 'buildings,', sum(1 for b in data['buildings'] if b['hittable']), 'with collapses')


main()
