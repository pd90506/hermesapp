"""Draws the Hermes app icon's layers (a chat bubble with a messenger's wing).

Writes wing.svg and bubble.svg into the Icon Composer document's Assets folder:

    python3 scripts/app-icon.py Apps/Shared/AppIcon.icon/Assets

The background gradients, glass and the dark, tinted and clear appearances are set in
Apps/Shared/AppIcon.icon/icon.json; open that file in Icon Composer (ships with Xcode) to preview.
"""
import math, os, sys
W = 1024
DX, DY = 6, -4  # shift the whole glyph to centre it

def taper(p0, p1, r0, r1):
    x0, y0 = p0; x1, y1 = p1
    d = math.hypot(x1 - x0, y1 - y0); phi = math.atan2(y1 - y0, x1 - x0)
    th = math.acos((r0 - r1) / d); pts = []; N = 32
    for i in range(N + 1):
        a = phi + th - 2 * th * i / N; pts.append((x1 + r1 * math.cos(a), y1 + r1 * math.sin(a)))
    for i in range(N + 1):
        a = phi - th - (2 * math.pi - 2 * th) * i / N; pts.append((x0 + r0 * math.cos(a), y0 + r0 * math.sin(a)))
    return 'M' + ' L'.join(f'{x + DX:.1f},{y + DY:.1f}' for x, y in pts) + ' Z'

def feathers(sx=500, sy=410, s=0.84):
    # top feather first; bases run down-left along the arm, feathers sweep back (left) and up
    specs = [(30, 1.00, 66, 34), (18, 0.84, 62, 31), (6, 0.69, 58, 28), (-6, 0.55, 54, 25)]
    out = []
    for i, (ang, L, r0, r1) in enumerate(specs):
        bx, by = sx - i * 26 * s, sy + i * 84 * s
        a = math.radians(ang); L *= 440 * s
        out.append(taper((bx, by), (bx - math.cos(a) * L, by - math.sin(a) * L), r0 * s, r1 * s))
    return out

def bubble():
    x0, y0, x1, y1, r = 430 + DX, 350 + DY, 850 + DX, 680 + DY, 160
    body = (f'M{x0+r},{y0} H{x1-r} A{r},{r} 0 0 1 {x1},{y0+r} V{y1-r} A{r},{r} 0 0 1 {x1-r},{y1} '
            f'H{x0+r} A{r},{r} 0 0 1 {x0},{y1-r} V{y0+r} A{r},{r} 0 0 1 {x0+r},{y0} Z')
    tail = f'M{x0+120},{y1-60} Q{x0+90},{y1+40} {x0+20},{y1+90} Q{x0+170},{y1+80} {x0+250},{y1-20} Z'
    return body, tail

GAP = 15  # half the gap between shapes, in points

def svg(defs, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">'
            f'<defs>{defs}</defs>{body}</svg>')

def mask(mid, cutters):
    cut = ''.join(f'<path d="{d}" fill="#000" stroke="#000" stroke-width="{2*GAP}" stroke-linejoin="round"/>' for d in cutters)
    return (f'<mask id="{mid}" maskUnits="userSpaceOnUse" x="0" y="0" width="{W}" height="{W}">'
            f'<rect width="{W}" height="{W}" fill="#fff"/>{cut}</mask>')

def wing_layer(c0, c1):
    fs = feathers(); body, tail = bubble()
    defs = (f'<linearGradient id="g" x1="0" y1="0" x2="0" y2="1" gradientUnits="objectBoundingBox">'
            f'<stop offset="0" stop-color="{c0}"/><stop offset="1" stop-color="{c1}"/></linearGradient>')
    parts = ''
    for i, d in enumerate(fs):
        defs += mask(f'm{i}', fs[:i] + [body, tail])
        parts += f'<path d="{d}" fill="url(#g)" mask="url(#m{i})"/>'
    return svg(defs, f'<g>{parts}</g>')

def bubble_layer(c0, c1):
    body, tail = bubble()
    defs = (f'<linearGradient id="g" x1="0" y1="{330+DY}" x2="0" y2="{780+DY}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{c0}"/><stop offset="1" stop-color="{c1}"/></linearGradient>')
    return svg(defs, f'<path d="{body}" fill="url(#g)"/><path d="{tail}" fill="url(#g)"/>')

if __name__ == '__main__':
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    open(f'{out}/wing.svg', 'w').write(wing_layer('#ffe7a0', '#ffb547'))
    open(f'{out}/bubble.svg', 'w').write(bubble_layer('#ffffff', '#e4ebff'))
