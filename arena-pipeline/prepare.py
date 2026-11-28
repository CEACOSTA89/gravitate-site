"""Step 1 of the arena pipeline: NYC building footprints -> buildings.json in the game's coordinates.

Reads the NYC Open Data "Building Footprints" export (dataset 5zhs-2jue: one row per building with its
outline, roof height and BIN), converts every outline to the game's scene coordinates (metres; +z uptown
along the avenues, +x the west side, origin at the arena centre), and marks the buildings the giants can
reach: the ones touching the strip along the avenue where the fight runs. Only those get fractured and
baked collapses; the rest stay solid.

    python prepare.py arena.json buildings.json

Download arena.json for the Flatiron arena with:
    curl -G "https://data.cityofnewyork.us/resource/5zhs-2jue.json" \
      --data-urlencode '$where=within_box(the_geom, 40.7452, -73.9928, 40.7393, -73.9848)' \
      --data-urlencode '$limit=5000' -o arena.json
"""
import json
import math
import sys

from shapely.geometry import Polygon, box
from shapely.validation import make_valid

# Must match ARENA and GRID in the game page, so the buildings land where the game expects them.
ARENA = {'name': 'Flatiron / Madison Square Park', 'lat': 40.74225, 'lon': -73.98800}
GRID = math.radians(29)             # Manhattan's avenues run about 29 degrees east of true north
FT = 0.3048
LANDMARK_BIN = '1016278'            # the Flatiron Building
MIN_HEIGHT = 3.0                    # metres; lower structures (sheds, kiosks) are left out
SIMPLIFY = 0.4                      # metres


def project(lat, lon):
    east = (lon - ARENA['lon']) * 111320 * math.cos(math.radians(ARENA['lat']))
    north = (lat - ARENA['lat']) * 111132
    across = east * math.cos(GRID) - north * math.sin(GRID)
    uptown = east * math.sin(GRID) + north * math.cos(GRID)
    return (-across, uptown)


def main(src, dst):
    rows = json.load(open(src))
    buildings = []
    for row in rows:
        h = float(row.get('height_roof') or 0) * FT
        if h < MIN_HEIGHT:
            continue
        geom = row['the_geom']
        polys = geom['coordinates'] if geom['type'] == 'MultiPolygon' else [geom['coordinates']]
        for i, rings in enumerate(polys):
            outer = [project(lat, lon) for lon, lat in rings[0]]
            poly = make_valid(Polygon(outer)).buffer(0).simplify(SIMPLIFY, preserve_topology=True)
            if poly.geom_type == 'MultiPolygon':
                poly = max(poly.geoms, key=lambda g: g.area)
            if poly.geom_type != 'Polygon' or poly.area < 4:
                continue
            pts = [(round(x, 2), round(z, 2)) for x, z in list(poly.exterior.coords)[:-1]]
            if Polygon(pts).exterior.is_ccw is False:      # counter-clockwise in (x, z)
                pts.reverse()
            key = 'bin' + row['bin'] + ('' if i == 0 else '.' + str(i))
            buildings.append({'key': key, 'bin': row['bin'], 'height': round(h, 2), 'pts': pts,
                              'year': row.get('construction_year'), 'landmark': row['bin'] == LANDMARK_BIN and i == 0})

    landmark = next(b for b in buildings if b['landmark'])
    lp = Polygon(landmark['pts'])
    # The fight's line runs uptown from the Flatiron's tip through its centre line (same as the game's setRail).
    rail_x = sum(x for x, _ in landmark['pts']) / len(landmark['pts'])
    tip_z = max(z for _, z in landmark['pts'])
    giant = landmark['height']                         # giants stand as tall as the Flatiron
    reach = 0.16 * giant + 4                           # the game knocks down what a giant of radius 0.16 h touches
    strip = box(rail_x - reach, tip_z - 3 * giant, rail_x + reach, tip_z + 4.5 * giant)
    for b in buildings:
        p = Polygon(b['pts'])
        b['hittable'] = bool(p.intersects(strip))
        b['area'] = round(p.area, 1)
    out = {'arena': ARENA, 'grid_deg': 29, 'source': 'NYC Open Data, Building Footprints (5zhs-2jue)',
           'rail': {'x': round(rail_x, 2), 'tipZ': round(tip_z, 2), 'giant': landmark['height']},
           'buildings': buildings}
    json.dump(out, open(dst, 'w'))
    hit = [b for b in buildings if b['hittable']]
    print(f'{len(buildings)} buildings, {len(hit)} the giants can reach; Flatiron {landmark["height"]} m, '
          f'area {lp.area:.0f} m2, rail x {rail_x:.1f}, tip z {tip_z:.1f}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
