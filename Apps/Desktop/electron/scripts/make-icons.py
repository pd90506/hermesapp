# Makes resources/icon.ico (Windows) and resources/icon.png (macOS; electron-builder
# turns it into .icns) from the Mac app's icon, Apps/Shared/AppIcon.icon: its dark
# art on its fill, as Icon Composer draws it. Needs Pillow.
#
#   python3 scripts/make-icons.py ../../Shared/AppIcon.icon/Assets/art-dark.png resources/icon.ico resources/icon.png
import sys
from PIL import Image, ImageDraw
art = Image.open(sys.argv[1]).convert('RGBA')
fill = (13, 17, 23, 255)

def tile(size, body, radius_ratio):
    """A rounded square `body` px wide centred on a `size` canvas, art scaled to it."""
    s = 4  # supersample
    big = size * s
    canvas = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    b = body * s
    off = (big - b) // 2
    mask = Image.new('L', (b, b), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, b - 1, b - 1], radius=int(b * radius_ratio), fill=255)
    layer = Image.new('RGBA', (b, b), fill)
    layer.alpha_composite(art.resize((b, b), Image.LANCZOS))
    layer.putalpha(mask)
    canvas.alpha_composite(layer, (off, off))
    return canvas.resize((size, size), Image.LANCZOS)

# Windows: the tile fills the icon, corners as Windows 11 app icons round them.
win = tile(256, 240, 0.18)
win.save(sys.argv[2], sizes=[(256, 256), (64, 64), (48, 48), (40, 40), (32, 32), (24, 24), (20, 20), (16, 16)])
# macOS: Apple's icon grid, an 824 body on a 1024 canvas with 22.37 % corners.
mac = tile(1024, 824, 0.2237)
mac.save(sys.argv[3])
