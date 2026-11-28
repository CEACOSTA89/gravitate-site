"""Placeholder facade, roof and concrete textures (until real facades from capture or generation replace them).

Each facade image covers 12 m x 14 m of wall: 4 window bays, 4 floors of 3.5 m. Run with Python + Pillow:
    python make_placeholder_textures.py textures/
"""
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 512
STYLES = {   # wall colour, window colour, frame colour, sill/cornice
    'facade_brick':     ((128, 62, 48), (52, 64, 78), (222, 214, 198), (176, 160, 140)),
    'facade_limestone': ((198, 188, 168), (48, 60, 74), (90, 84, 76), (214, 206, 188)),
    'facade_beige':     ((176, 158, 128), (56, 66, 80), (238, 232, 218), (150, 134, 108)),
    'facade_modern':    ((96, 108, 120), (64, 92, 118), (150, 160, 170), (120, 130, 140)),
    'facade_landmark':  ((214, 198, 168), (58, 66, 76), (176, 160, 130), (232, 222, 200)),
}


def noise(img, amount, seed):
    rnd = random.Random(seed)
    px = img.load()
    for y in range(S):
        for x in range(S):
            d = rnd.randint(-amount, amount)
            r, g, b = px[x, y]
            px[x, y] = (max(0, min(255, r + d)), max(0, min(255, g + d)), max(0, min(255, b + d)))


def facade(name, wall, glass, frame, trim, out):
    img = Image.new('RGB', (S, S), wall)
    d = ImageDraw.Draw(img)
    bay, floor = S // 4, S // 4
    modern = name == 'facade_modern'
    for f in range(4):
        y0 = f * floor
        d.rectangle([0, y0, S, y0 + 6], fill=trim)                     # floor line / sill band
        for b in range(4):
            x0 = b * bay
            if modern:
                d.rectangle([x0 + 6, y0 + 14, x0 + bay - 6, y0 + floor - 8], fill=glass, outline=frame, width=4)
                d.line([x0 + bay // 2, y0 + 14, x0 + bay // 2, y0 + floor - 8], fill=frame, width=3)
            else:
                wx0, wx1 = x0 + bay * 0.26, x0 + bay * 0.74
                wy0, wy1 = y0 + floor * 0.22, y0 + floor * 0.86
                d.rectangle([wx0 - 4, wy0 - 4, wx1 + 4, wy1 + 4], fill=frame)
                d.rectangle([wx0, wy0, wx1, wy1], fill=glass)
                d.line([wx0, (wy0 + wy1) / 2, wx1, (wy0 + wy1) / 2], fill=frame, width=4)
                d.rectangle([wx0 - 8, wy1 + 4, wx1 + 8, wy1 + 10], fill=trim)
                # a faint reflection
                d.polygon([(wx0, wy0), (wx0 + (wx1 - wx0) * 0.45, wy0), (wx0, wy0 + (wy1 - wy0) * 0.5)], fill=tuple(min(255, c + 30) for c in glass))
        if name == 'facade_brick':
            for row in range(0, floor, 8):
                d.line([0, y0 + row, S, y0 + row], fill=tuple(c - 14 for c in wall), width=1)
    noise(img, 10, name)
    img.filter(ImageFilter.SMOOTH).save(out + '/' + name + '.jpg', quality=88)


def plain(name, colour, amount, out):
    img = Image.new('RGB', (S, S), colour)
    noise(img, amount, name)
    img.filter(ImageFilter.SMOOTH).save(out + '/' + name + '.jpg', quality=85)


if __name__ == '__main__':
    out = sys.argv[1]
    for name, (w, g, f, t) in STYLES.items():
        facade(name, w, g, f, t, out)
    plain('roof', (92, 92, 96), 18, out)
    plain('concrete', (128, 124, 118), 22, out)
    print('textures written to', out)
