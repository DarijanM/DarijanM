# GreenStar (original, 2001) terminal + nosac za JD 7810 – parametarska izrada
# Pokretanje: blender -b --factory-startup --python gs_build.py -- high|game out.blend
# Koordinate (Blender, lokalno u gsTerminal): X poprijeko (0 = sredina), Y gore (0 = dno kucista),
# Z prema vozacu (0 = ravnina lica, straznja ploca Z = -64). Gradi se u mm, na kraju *0.001.
import bpy, bmesh, math, sys
from mathutils import Vector, Matrix
from mathutils.geometry import delaunay_2d_cdt

argv = sys.argv[sys.argv.index('--') + 1:]
Q = argv[0]; OUT = argv[1]
HIGH = Q == 'high'
TEXDIR = '/tmp/claude-0/gs/build'
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'

P = dict(
    np_house=12 if HIGH else 4,     # segmenti po kutu tlocrta kucista
    np_rec=8 if HIGH else 3,        # kutovi udubljenja
    np_key=6 if HIGH else 2,        # kutovi tipki
    sf=4 if HIGH else 1,            # zaobljenje prednjeg ruba
    sb=5 if HIGH else 1,            # zaobljenje straznjeg ruba
    srim=2 if HIGH else 0,          # rub udubljenja
    skey=3 if HIGH else 1,          # zaobljenje vrha tipke
    txt_res=8 if HIGH else 2,
    cyl=48 if HIGH else 12,
    cyl_s=24 if HIGH else 8,
    bev_seg=3 if HIGH else 1,
)

# ---------------------------------------------------------------- dimenzije (nacrt v6, mm; x 0..152, y 0..305)
W, H, D = 152.0, 305.0, 64.0
OX = -76.0                          # pomak u X da je sredina 0
R_PLAN, RF, RB = 9.0, 1.5, 3.0
BEZ = (6.1, 126.7, 127.4, 286.9, 5.0, 2.0)          # x0,y0,x1,y1,r,dubina
LCD = (14.6, 136.7, 120.4, 272.9)
SLOTS = {'kp': (18.9, 22.5, 103.2, 110.3, 5.0), 'fk': (111.4, 22.5, 149.1, 110.3, 6.0), 'ag': (129.2, 144.6, 148.8, 279.7, 4.0)}
SLOT_D = 3.0
KEY_TOP = 1.0
AG_Y = {'A': 256.7, 'B': 239.0, 'C': 221.3, 'D': 203.8, 'E': 186.5, 'F': 169.2, 'G': 152.1}
AG_X = 139.0
BRIGHT_Y = 273.7
KP_COLS = [32.45, 61.05, 89.65]
KP_ROWS = [99.4, 77.4, 55.4, 33.4]
FK_X = 130.25
GROOVE = dict(xp0=50, xp1=102, yp0=40, yp1=95, xc0=56, xc1=96, yc1=205, d=6.0)

MAT_DEF = [  # ime, boja (sRGB hex) ; colorScale se pise u README
    ('series7810Gs_housing_mat', '5a4434', 0.55),
    ('series7810Gs_slot_mat', '2a2a2c', 0.5),
    ('series7810Gs_key_mat', '4e5155', 0.45),
    ('series7810Gs_print_mat', 'f2f2ee', 0.5),
    ('series7810Gs_screen_mat', '1b1f1a', 0.2),
    ('series7810Gs_lcdSeg_mat', 'f2f2ee', 0.3),
    ('series7810ExtrasI_steelBlack_mat', '1e2124', 0.45),
    ('series7810Gs_yellow_mat', 'fbe073', 0.4),
    ('series7810ExtrasI_rubber_mat', '141414', 0.75),
    ('series7810ExtrasI_steel_mat', 'a8abae', 0.3),
]

def srgb(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]

def make_mats():
    M = {}
    for name, hx, rough in MAT_DEF:
        m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        m.use_nodes = True
        b = m.node_tree.nodes.get('Principled BSDF')
        b.inputs['Base Color'].default_value = (*srgb(hx), 1)
        b.inputs['Roughness'].default_value = rough
        b.inputs['Metallic'].default_value = 0.6 if 'steel' in name else 0.0
        if name.endswith(('screen_mat', 'lcdSeg_mat')):
            b.inputs['Emission Color'].default_value = (*srgb(hx), 1)
            b.inputs['Emission Strength'].default_value = 0.6 if 'lcdSeg' in name else 0.15
        if name.endswith('screen_mat'):
            nt = m.node_tree; tx = nt.nodes.new('ShaderNodeTexImage')
            tx.image = bpy.data.images.load('//series7810Gs_screen_v2_diffuse.png' if False else TEXDIR + '/series7810Gs_screen_v2_diffuse.png')
            tx.image.filepath = '//series7810Gs_screen_v2_diffuse.png'
            nt.links.new(tx.outputs['Color'], b.inputs['Base Color']); nt.links.new(tx.outputs['Color'], b.inputs['Emission Color'])
        m.diffuse_color = (*srgb(hx), 1)
        M[name.split('_')[1] if name.startswith('series7810Gs') else name.split('_')[1]] = m
    return M

# ---------------------------------------------------------------- 2D pomocne
def rr(x0, y0, x1, y1, r, n, d=0.0):
    """zaobljeni pravokutnik CCW; d = pomak (+ van)"""
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hw, hh = (x1 - x0) / 2 + d, (y1 - y0) / 2 + d
    r = max(0.05, min(r + d, hw, hh))
    pts = []
    for ox, oy, a0 in ((cx + hw - r, cy + hh - r, 0), (cx - hw + r, cy + hh - r, 90),
                       (cx - hw + r, cy - hh + r, 180), (cx + hw - r, cy - hh + r, 270)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / max(n, 1)) if n > 0 else math.radians(a0 + 45)
            pts.append((ox + r * math.cos(a), oy + r * math.sin(a)))
            if n == 0: break
    return pts

# ---------------------------------------------------------------- graditelj mesha
class MB:
    def __init__(s):
        s.v = []; s.f = []; s.m = []
    def av(s, p):
        s.v.append(tuple(p)); return len(s.v) - 1
    def ring(s, pts, z):
        return [s.av((x, y, z)) for x, y in pts]
    def face(s, idx, mat):
        s.f.append(list(idx)); s.m.append(mat)
    def loft(s, a, b, mat):
        n = len(a)
        for i in range(n):
            j = (i + 1) % n
            s.face([a[i], a[j], b[j], b[i]], mat)
    def cap(s, loops, mat, glyphs=None, gmat=None):
        """loops: [vanjska, rupa, ...] (indeksi), ravnina z iz prvog vrha.
        glyphs: lista trokuta [(x,y),..] u istoj ravnini -> materijal gmat (parnost preklapanja)."""
        z = s.v[loops[0][0]][2]
        co, imap, faces = [], [], []
        for lp in loops:
            f = []
            for vi in lp:
                f.append(len(co)); co.append(Vector(s.v[vi][:2])); imap.append(vi)
            faces.append(f)
        nl = len(faces)
        for tri in (glyphs or []):
            f = []
            for p in tri:
                f.append(len(co)); co.append(Vector(p)); imap.append(None)
            faces.append(f)
        vco, _, ofaces, overts, _, ofac = delaunay_2d_cdt(co, [], faces, 1, 1e-5)
        vm = []
        for k, c in enumerate(vco):
            src = next((imap[o] for o in overts[k] if imap[o] is not None), None)
            vm.append(src if src is not None else s.av((c.x, c.y, z)))
        for fc, of in zip(ofaces, ofac):
            loopc = sum(1 for o in of if o < nl)
            if loopc % 2 == 0: continue
            g = sum(1 for o in of if o >= nl)
            s.face([vm[i] for i in fc], gmat if g % 2 == 1 else mat)
    def merge(s, other, off=(0, 0, 0)):
        b = len(s.v)
        s.v += [(x + off[0], y + off[1], z + off[2]) for x, y, z in other.v]
        s.f += [[i + b for i in f] for f in other.f]; s.m += other.m

def to_object(mb, name, mats, origin=(0, 0, 0), scale=0.001, flip_check=True):
    me = bpy.data.meshes.new(name)
    ox, oy, oz = origin
    me.from_pydata([((x - ox) * scale, (y - oy) * scale, (z - oz) * scale) for x, y, z in mb.v], [], mb.f)
    me.update()
    for m in mats: me.materials.append(m)
    for p, mi in zip(me.polygons, mb.m): p.material_index = mi
    bm = bmesh.new(); bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.00002)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=0.00001)
    if flip_check:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = (ox * scale, oy * scale, oz * scale)
    return ob

def empty(name, loc, parent=None, size=0.01):
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = size; e.empty_display_type = 'PLAIN_AXES'
    bpy.context.scene.collection.objects.link(e)
    e.location = loc
    if parent is not None:
        e.parent = parent; e.matrix_parent_inverse = Matrix.Identity(4)
    return e

# ---------------------------------------------------------------- tekst -> trokuti / tijelo
_font = None
def font():
    global _font
    if _font is None: _font = bpy.data.fonts.load(FONT)
    return _font

def text_mesh(txt, size, extrude=0.0, res=None, spacing=1.0):
    cu = bpy.data.curves.new('t', 'FONT'); cu.body = txt; cu.font = font()
    cu.size = size; cu.align_x = 'CENTER'; cu.align_y = 'CENTER'
    cu.resolution_u = res or P['txt_res']; cu.extrude = extrude; cu.space_character = spacing
    cu.fill_mode = 'BOTH'
    ob = bpy.data.objects.new('t', cu); bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    bpy.data.objects.remove(ob); bpy.data.curves.remove(cu)
    # cap height normalisation: align_y CENTER uses font box; re-centre on real bbox
    xs = [v.co.x for v in me.vertices]; ys = [v.co.y for v in me.vertices]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    for v in me.vertices: v.co.x -= cx; v.co.y -= cy
    return me

def glyph_tris(txt, size, cx, cy, res=None, spacing=1.0):
    me = text_mesh(txt, size, 0.0, res, spacing)
    me.calc_loop_triangles()
    out = [[(me.vertices[i].co.x + cx, me.vertices[i].co.y + cy) for i in t.vertices] for t in me.loop_triangles]
    bpy.data.meshes.remove(me)
    return out

def disc_tris(cx, cy, r0, r1, a0, a1, n):
    """prsten/isjecak kao trokuti (r0=0 -> pun)"""
    tris = []
    for i in range(n):
        t0 = a0 + (a1 - a0) * i / n; t1 = a0 + (a1 - a0) * (i + 1) / n
        p0 = (cx + r1 * math.cos(t0), cy + r1 * math.sin(t0)); p1 = (cx + r1 * math.cos(t1), cy + r1 * math.sin(t1))
        if r0 <= 0:
            tris.append([(cx, cy), p0, p1])
        else:
            q0 = (cx + r0 * math.cos(t0), cy + r0 * math.sin(t0)); q1 = (cx + r0 * math.cos(t1), cy + r0 * math.sin(t1))
            tris += [[q0, p0, p1], [q0, p1, q1]]
    return tris

# ================================================================ KUCISTE
MI_H, MI_SLOT, MI_KEY, MI_PRINT = 0, 1, 2, 3

def recess(mb, x0, y0, x1, y1, r, depth, mat, n, floor_holes=None, floor=True):
    """udubljenje: vraca vanjski prsten ruba na z=0 (rupa u licu)"""
    rim = 0.4 if P['srim'] else 0.0
    top = mb.ring(rr(x0, y0, x1, y1, r, n, rim), 0.0)
    prev = top
    for k in range(1, P['srim'] + 1):
        a = math.radians(90 * k / P['srim'])
        ring = mb.ring(rr(x0, y0, x1, y1, r, n, rim - rim * math.sin(a)), -rim + rim * math.cos(a))
        mb.loft(prev, ring, MI_H if k < P['srim'] else mat); prev = ring
    bot = mb.ring(rr(x0, y0, x1, y1, r, n), -depth)
    mb.loft(prev, bot, mat)
    if floor:
        mb.cap([bot] + (floor_holes or []), mat)
    return top, bot

def build_housing(keys_into=None):
    mb = MB()
    # obris i prstenovi boka
    def outline(d): return rr(0, 0, W, H, R_PLAN, P['np_house'], d)
    rings = []
    for k in range(P['sf'] + 1):
        a = math.radians(90 * k / P['sf'])
        rings.append(mb.ring(outline(-RF + RF * math.sin(a)), -RF + RF * math.cos(a)))
    face_ring = rings[0]
    if HIGH:   # razdjelna linija prednja/straznja skoljka
        for d, z in ((0, -19.6), (-0.5, -19.85), (-0.5, -20.15), (0, -20.4)):
            rings.append(mb.ring(outline(d), z))
    for k in range(P['sb'] + 1):
        a = math.radians(90 * k / P['sb'])
        rings.append(mb.ring(outline(-RB + RB * math.cos(a)), -D + RB - RB * math.sin(a)))
    for a, b in zip(rings, rings[1:]): mb.loft(a, b, MI_H)
    back_ring = rings[-1]

    # --- lice: udubljenja
    bx0, by0, bx1, by1, br, bd = BEZ
    lcd_top = mb.ring(rr(*LCD, 0.6, 2), -bd)
    lcd_bot = mb.ring(rr(*LCD, 0.6, 2), -bd - 1.2)
    mb.loft(lcd_top, lcd_bot, MI_SLOT)
    mb.cap([lcd_bot], MI_SLOT)       # skriveno iza ekrana (zatvara tijelo)
    bez_top, _ = recess(mb, bx0, by0, bx1, by1, br, bd, MI_H, P['np_rec'], floor_holes=[lcd_top])
    holes = [bez_top]
    for key, (x0, y0, x1, y1, r) in SLOTS.items():
        t, _ = recess(mb, x0, y0, x1, y1, r, SLOT_D, MI_SLOT, P['np_rec']); holes.append(t)
    mb.cap([face_ring] + holes, MI_H)

    # --- JOHN DEERE (izdignuto 0.4 mm na dnu okvira, iznad LCD-a)
    me = text_mesh('JOHN DEERE', 6.0, 0.2, spacing=1.08)
    jy = (LCD[3] + by1) / 2; jx = (LCD[0] + LCD[2]) / 2
    sub = MB(); sub.v = [(v.co.x + jx, v.co.y + jy, v.co.z - bd + 0.2) for v in me.vertices]
    sub.f = [list(p.vertices) for p in me.polygons]; sub.m = [MI_H] * len(sub.f)
    bpy.data.meshes.remove(me); mb.merge(sub)

    # --- straga: utor (lastin rep) + ulazni dzep
    g = GROOVE
    surf = [(g['xp0'], g['yp0']), (g['xp1'], g['yp0']), (g['xp1'], g['yp1']), (g['xc1'], g['yp1']),
            (g['xc1'], g['yc1']), (g['xc0'], g['yc1']), (g['xc0'], g['yp1']), (g['xp0'], g['yp1'])]
    deep = [(g['xp0'], g['yp0']), (g['xp1'], g['yp0']), (g['xp1'], g['yp1']), (g['xp1'], g['yp1']),
            (g['xp1'], g['yc1']), (g['xp0'], g['yc1']), (g['xp0'], g['yp1']), (g['xp0'], g['yp1'])]
    gs = mb.ring(surf, -D); gd = mb.ring(deep, -D + g['d'])
    for i in range(8):
        j = (i + 1) % 8
        mb.face([gs[i], gs[j], gd[j], gd[i]], MI_H)
    mb.face([gd[0], gd[1], gd[2], gd[4], gd[5], gd[6]], MI_H)
    mb.cap([back_ring, gs], MI_H)

    # --- konektor kabela (dolje straga)
    cx0, cx1, cy0, cy1 = 64.0, 88.0, 20.0, 34.0
    cr = mb.ring(rr(cx0, cy0, cx1, cy1, 2.0, P['np_rec']), -D + 0.5)
    cr2 = mb.ring(rr(cx0, cy0, cx1, cy1, 2.0, P['np_rec']), -D - 7.0)
    cr3 = mb.ring(rr(cx0, cy0, cx1, cy1, 2.0, P['np_rec'], -1.0), -D - 8.0)
    mb.loft(cr, cr2, MI_SLOT); mb.loft(cr2, cr3, MI_SLOT); mb.cap([cr3], MI_SLOT)
    mb.cap([cr], MI_SLOT)
    if HIGH:  # 4 vijka straznje skoljke
        for sx, sy in ((14, 14), (138, 14), (14, 291), (138, 291)):
            c0 = mb.ring([(sx + 3.5 * math.cos(2 * math.pi * i / 24), sy + 3.5 * math.sin(2 * math.pi * i / 24)) for i in range(24)], -D + 0.2)
            c1 = mb.ring([(sx + 3.5 * math.cos(2 * math.pi * i / 24), sy + 3.5 * math.sin(2 * math.pi * i / 24)) for i in range(24)], -D - 0.4)
            mb.loft(c0, c1, MI_SLOT); mb.cap([c1], MI_SLOT); mb.cap([c0], MI_SLOT)
    return mb

# ================================================================ TIPKE
def key_specs():
    ks = []
    lab = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '·', '0', 'CLR']
    nm = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'Dot', '0', 'Clr']
    for i, (l, n) in enumerate(zip(lab, nm)):
        r, c = divmod(i, 3)
        ks.append(dict(name='gsKey' + n, cx=KP_COLS[c], cy=KP_ROWS[r], w=22, h=12, r=2.0, txt=l, ts=5.0 if len(l) == 1 else 3.6))
    for l, y in zip(['PAGE', 'SETUP', 'INFO', 'RUN'], KP_ROWS):
        ks.append(dict(name='gsKey' + l.capitalize(), cx=FK_X, cy=y, w=23, h=11, r=5.5, txt=l, ts=3.4))
    for l, y in AG_Y.items():
        ks.append(dict(name='gsKey' + l, cx=AG_X, cy=y, w=15.0, h=9.6, r=2.0, txt=l, ts=5.0))
    ks.append(dict(name='gsKeyBright', cx=AG_X, cy=BRIGHT_Y, w=11.3, h=7.0, r=3.5, txt='BRIGHT', ts=0))
    return ks

def build_key(k):
    mb = MB(); n = P['np_key']
    x0, x1, y0, y1 = k['cx'] - k['w'] / 2, k['cx'] + k['w'] / 2, k['cy'] - k['h'] / 2, k['cy'] + k['h'] / 2
    kr = 0.9
    base = mb.ring(rr(x0, y0, x1, y1, k['r'], n), -SLOT_D - 0.05)
    prev = mb.ring(rr(x0, y0, x1, y1, k['r'], n), KEY_TOP - kr)
    mb.loft(base, prev, MI_KEY)
    for s in range(1, P['skey'] + 1):
        a = math.radians(90 * s / P['skey'])
        ring = mb.ring(rr(x0, y0, x1, y1, k['r'], n, -kr + kr * math.cos(a)), KEY_TOP - kr + kr * math.sin(a))
        mb.loft(prev, ring, MI_KEY); prev = ring
    if k['txt'] == 'BRIGHT':
        nn = 32 if HIGH else 12
        gl = disc_tris(k['cx'], k['cy'], 1.85, 2.4, 0, 2 * math.pi, nn) + disc_tris(k['cx'], k['cy'], 0, 1.45, math.pi / 2, 3 * math.pi / 2, nn // 2)
    elif k['txt'] == '·':
        gl = disc_tris(k['cx'], k['cy'] - 1.6, 0, 1.0, 0, 2 * math.pi, 16 if HIGH else 8)
    else:
        gl = glyph_tris(k['txt'], k['ts'] * 1.36, k['cx'], k['cy'])
    mb.cap([prev], MI_KEY, glyphs=gl, gmat=MI_PRINT)
    mb.cap([base], MI_KEY)
    return mb

# ================================================================ NOSAC (bmesh dijelovi + bevel)
def bm_obj(bm, name, mat_idx_faces=None):
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(ob)
    return ob

def extrude_poly(pts, axis, a0, a1):
    """2D poligon (u,v) izvucen duz osi 'x'/'y'/'z' od a0 do a1; vraca bmesh"""
    bm = bmesh.new()
    def P3(u, v, w):
        if axis == 'x': return (w, u, v)      # u=Y, v=Z
        if axis == 'y': return (u, w, v)      # u=X, v=Z
        return (u, v, w)                      # u=X, v=Y
    A = [bm.verts.new(P3(u, v, a0)) for u, v in pts]
    B = [bm.verts.new(P3(u, v, a1)) for u, v in pts]
    bm.faces.new(A); bm.faces.new(B[::-1])
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new([A[i], A[j], B[j], B[i]])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm

def circle(cx, cy, r, n, a0=0, a1=2 * math.pi, closed=True):
    m = n if closed else n + 1
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(m)]

def boxp(x0, y0, x1, y1): return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]

PARTS = []   # (bmesh, mat_name, bevel_width)
def part(bm, mat, bev=0.0):
    PARTS.append((bm, mat, bev))

def finish_parts(name, mats_order, origin, parent=None):
    """bake bevel per dio, spoji u jedan mesh s lokalnim ishodistem 'origin' (mm)"""
    out = bmesh.new()
    for bm, mat, bev in PARTS:
        me = bpy.data.meshes.new('p'); bm.to_mesh(me); bm.free()
        ob = bpy.data.objects.new('p', me); bpy.context.scene.collection.objects.link(ob)
        if bev > 0:
            md = ob.modifiers.new('b', 'BEVEL'); md.width = bev; md.segments = P['bev_seg']
            md.limit_method = 'ANGLE'; md.angle_limit = math.radians(35); md.harden_normals = False
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        me2 = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
        nf0 = len(out.faces)
        out.from_mesh(me2)
        out.faces.ensure_lookup_table()
        mi = next(i for i, n in enumerate(mats_order) if n.split('_')[1] == mat or n.endswith('_' + mat + '_mat'))
        for f in list(out.faces)[nf0:]: f.material_index = mi
        bpy.data.objects.remove(ob); bpy.data.meshes.remove(me); bpy.data.meshes.remove(me2)
    PARTS.clear()
    for v in out.verts: v.co = (v.co - Vector(origin)) * 0.001
    me = bpy.data.meshes.new(name); out.to_mesh(me); out.free()
    for mn in mats_order: me.materials.append(bpy.data.materials[mn])
    ob = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(ob)
    ob.location = Vector(origin) * 0.001
    if parent is not None: reparent(ob, parent)
    return ob

def reparent(ob, par):
    wl = ob.location.copy()
    ob.parent = par; ob.matrix_parent_inverse = Matrix.Identity(4)
    ob.location = wl - par.matrix_world.translation
    bpy.context.view_layer.update()

def cyl(axis, cx, cy, r, a0, a1, n=None):
    return extrude_poly(circle(cx, cy, r, n or P['cyl']), axis, a0, a1)

def hexagon(axis, cx, cy, s, a0, a1):
    r = s / math.sqrt(3)
    return extrude_poly([(cx + r * math.cos(math.pi / 6 + i * math.pi / 3), cy + r * math.sin(math.pi / 6 + i * math.pi / 3)) for i in range(6)], axis, a0, a1)

def star_knob(xa, xb, cy, cz, R=17.0, lobes=5):
    n = 120 if HIGH else 30
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        rr_ = R * (0.86 + 0.14 * math.cos(lobes * t))
        pts.append((cy + rr_ * math.cos(t), cz + rr_ * math.sin(t)))
    return extrude_poly(pts, 'x', xa, xb)

def profile_lug(cy, cz, r, z_end, n):
    """profil (u,v): polukrug radijusa r oko osi (cy,cz) na strani suprotnoj od z_end + pravokutnik do z_end"""
    a0 = 0.0 if z_end < cz else math.pi
    arc = [(cy + r * math.cos(a0 + math.pi * i / n), cz + r * math.sin(a0 + math.pi * i / n)) for i in range(n + 1)]
    return arc + [(arc[-1][0], z_end), (arc[0][0], z_end)]

# ---------------------------------------------------------------- nosac: geometrija (mm, okvir terminala)
AX_TILT = (170.0, -90.0)     # (Y, Z) os nagiba (paralelna X)
AX_SWIV = (0.0, -160.0)      # (X, Z) os okretanja (paralelna Y)
Z_PLATE = -191.0

def build_mount(root):
    yA, zA = AX_TILT
    xS, zS = AX_SWIV
    # ---------- gsMountParts (stezna ploca na stupu + usice + osovina)
    part(extrude_poly(rr(-30, 120, 30, 220, 6, 4 if not HIGH else 8), 'z', Z_PLATE, Z_PLATE + 6), 'steelBlack', 1.0)
    for yb in (135.0, 205.0):
        part(cyl('z', 0, yb, 8.5, Z_PLATE + 6, Z_PLATE + 7.5, P['cyl_s']), 'steel', 0.3)            # podloska
        part(hexagon('z', 0, yb, 13.0, Z_PLATE + 7.5, Z_PLATE + 12.8), 'steel', 0.6)              # glava M8
    for y0, y1 in ((152.0, 159.0), (181.0, 188.0)):     # usice okretnog zgloba (vodoravne ploce)
        part(extrude_poly(profile_lug(xS, zS, 15.0, Z_PLATE + 5.0, 16 if HIGH else 6), 'y', y0, y1), 'steelBlack', 1.2)
    part(cyl('y', xS, zS, 5.0, 148.0, 192.0, P['cyl_s']), 'steel', 0.4)
    part(cyl('y', xS, zS, 7.5, 188.0, 192.5, P['cyl_s']), 'steel', 0.6)
    part(cyl('y', xS, zS, 7.5, 147.5, 152.0, P['cyl_s']), 'steel', 0.6)
    base = finish_parts('gsMountParts', ['series7810ExtrasI_steelBlack_mat', 'series7810ExtrasI_steel_mat'], (0, yA, Z_PLATE), root)

    # ---------- gsMountSwivel (krak + vilica nagiba + vijak + zuti gumb)
    part(cyl('y', xS, zS, 14.0, 159.5, 180.5), 'steelBlack', 1.2)                                 # glavina okretnog zgloba
    part(extrude_poly(rr(-12.5, 162, 12.5, 178, 3.0, 4 if HIGH else 1), 'z', zS + 8, -104.0), 'steelBlack', 0)   # krak 25x16
    part(extrude_poly(boxp(-14.0, 158.0, 14.0, 182.0), 'z', -112.0, -102.0), 'steelBlack', 1.5)      # most vilice
    for xa, xb in ((-14.0, -8.0), (8.0, 14.0)):
        prof = profile_lug(yA, zA, 12.0, -108.0, 24 if HIGH else 8)
        part(extrude_poly(prof, 'x', xa, xb), 'steelBlack', 1.2)
    part(cyl('x', yA, zA, 4.0, -19.0, 16.0, P['cyl_s']), 'steel', 0.3)                              # vijak
    part(hexagon('x', yA, zA, 13.0, -19.5, -14.0), 'steel', 0.6)                                     # matica
    part(star_knob(16.0, 27.0, yA, zA, R=15.0), 'yellow', 1.5)                                               # zuti zatezni gumb
    part(cyl('x', yA, zA, 9.0, 14.0, 16.5, P['cyl_s']), 'yellow', 0.5)
    sw = finish_parts('gsMountSwivel', ['series7810ExtrasI_steelBlack_mat', 'series7810ExtrasI_steel_mat', 'series7810Gs_yellow_mat'], (xS, yA, zS), base)

    # ---------- gsMountTilt (usica + adapter + pero lastinog repa + zasun)
    lug = profile_lug(yA, zA, 10.0, -71.0, 24 if HIGH else 8)
    part(extrude_poly(lug, 'x', -7.5, 7.5), 'steelBlack', 1.0)
    part(extrude_poly(rr(-32, 130, 32, 210, 5, 4 if HIGH else 2), 'z', -72.0, -64.2), 'steelBlack', 1.2)
    g = GROOVE; cl = 0.5
    w_out, w_in = (g['xc1'] - g['xc0']) / 2 - cl, (g['xp1'] - g['xp0']) / 2 - cl
    dov = [(-w_out, -64.2), (w_out, -64.2), (w_in, -D + g['d'] - 0.4), (-w_in, -D + g['d'] - 0.4)]
    part(extrude_poly(dov, 'y', 155.0, g['yc1'] - 0.5), 'steelBlack', 0.4)
    part(extrude_poly(rr(-9, 133, 9, 141, 3.5, 4 if HIGH else 1), 'z', -78.0, -71.5), 'yellow', 0.8)   # zasun
    tl = finish_parts('gsMountTilt', ['series7810ExtrasI_steelBlack_mat', 'series7810Gs_yellow_mat'], (0, yA, zA), sw)
    return base, sw, tl

def build_cable(parent):
    pts = [(0, 27, -72), (0, 26, -80), (2, 40, -96), (5, 95, -108), (3, 140, -118), (0, 156.5, -128),
           (0, 156.5, -142), (0, 150, -168), (0, 132, -182), (0, 118, -196)]
    cu = bpy.data.curves.new('cab', 'CURVE'); cu.dimensions = '3D'
    sp = cu.splines.new('NURBS'); sp.points.add(len(pts) - 1)
    for p, c in zip(sp.points, pts): p.co = (c[0] * 0.001, c[1] * 0.001, c[2] * 0.001, 1)
    sp.use_endpoint_u = True; sp.order_u = 4
    cu.bevel_depth = 0.0035; cu.bevel_resolution = 3 if HIGH else 1; cu.resolution_u = 10 if HIGH else 3
    cu.use_fill_caps = True
    ob = bpy.data.objects.new('cab', cu); bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg)); me.name = 'gsMountCable'
    bpy.data.objects.remove(ob); bpy.data.curves.remove(cu)
    # zastita kabela kod konektora
    bm = bmesh.new(); bm.from_mesh(me)
    nb = cyl('z', 0, 27, 5.5, -79.0, -71.5, P['cyl_s']); me_b = bpy.data.meshes.new('b'); nb.to_mesh(me_b); nb.free()
    for v in me_b.vertices: v.co *= 0.001
    bm.from_mesh(me_b); bpy.data.meshes.remove(me_b)
    bm.to_mesh(me); bm.free()
    me.materials.append(bpy.data.materials['series7810ExtrasI_rubber_mat'])
    o = bpy.data.objects.new('gsMountCable', me); bpy.context.scene.collection.objects.link(o)
    for v in me.vertices: v.co -= parent.matrix_world.translation
    o.parent = parent; o.matrix_parent_inverse = Matrix.Identity(4)
    return o

# ================================================================ SKLAPANJE
def main():
    for o in list(bpy.data.objects): bpy.data.objects.remove(o)
    make_mats()
    MATS_T = [bpy.data.materials[n] for n in ('series7810Gs_housing_mat', 'series7810Gs_slot_mat', 'series7810Gs_key_mat', 'series7810Gs_print_mat')]

    root = empty('gsTerminalMount', Vector((0, AX_TILT[0], Z_PLATE)) * 0.001, size=0.03)
    base, sw, tl = build_mount(root)
    term = empty('gsTerminal', (0, 0, 0), size=0.05)
    reparent(term, tl)
    cable = build_cable(root)

    hb = build_housing()
    keys = key_specs()
    # premjesti u X (sredina 0)
    def shift(mb):
        mb.v = [(x + OX, y, z) for x, y, z in mb.v]; return mb
    hb = shift(hb)
    for k in keys: k['cx'] += OX
    key_objs = []
    if HIGH:
        hous = to_object(hb, 'gsHousing', MATS_T)
        reparent(hous, term)
        for k in keys:
            kb = build_key(dict(k, cx=k['cx']))
            ko = to_object(kb, k['name'], MATS_T, origin=(k['cx'], k['cy'], KEY_TOP))
            reparent(ko, term); key_objs.append(ko)
    else:
        for k in keys:
            hb.merge(build_key(k))
        hous = to_object(hb, 'gsHousing', MATS_T)
        reparent(hous, term)
        for k in keys:
            e = empty(k['name'], Vector((k['cx'], k['cy'], KEY_TOP)) * 0.001, size=0.004)
            reparent(e, term); key_objs.append(e)

    # --- zaslon
    lx0, ly0, lx1, ly1 = LCD[0] + OX, LCD[1], LCD[2] + OX, LCD[3]
    sm = MB(); s = sm.ring([(lx0, ly0), (lx1, ly0), (lx1, ly1), (lx0, ly1)], -3.0); sm.face(s, 0)
    scr = to_object(sm, 'gsScreen', [bpy.data.materials['series7810Gs_screen_mat']], flip_check=False)
    reparent(scr, term)
    me = scr.data; uv = me.uv_layers.new(name='UVMap')
    for lp in me.loops:
        co = me.vertices[lp.vertex_index].co
        uv.data[lp.index].uv = ((co.x * 1000 - lx0) / (lx1 - lx0), (co.y * 1000 - ly0) / (ly1 - ly0))
    # sidra teksta – redovi tocno u visini tipki A-G
    zt = -2.5
    x0, x1 = lx0 + 4.0, lx1 - 4.0
    yA, yG = AG_Y['A'], AG_Y['G']; half = (yA - yG) / 12
    hb_bot = yA + half; fb_top = yG - half
    yhb = (ly1 + hb_bot) / 2; yfb = (fb_top + ly0) / 2
    for c, y in AG_Y.items():
        empty('gsRow' + c, Vector((x0, y, zt)) * 0.001, scr, 0.004)
        empty('gsVal' + c, Vector((x1, y, zt)) * 0.001, scr, 0.004)
    empty('gsHdr', Vector(((lx0 + lx1) / 2, yfb, zt)) * 0.001, scr, 0.004)
    empty('gsFoot', Vector((x0, yfb, zt)) * 0.001, scr, 0.004)
    empty('gsScreenGlow', Vector(((lx0 + lx1) / 2, (ly0 + ly1) / 2, zt)) * 0.001, scr, 0.004)
    empty('gsLightbar', Vector(((lx0 + lx1) / 2, yhb, -2.9)) * 0.001, scr, 0.004)
    segw = (x1 - x0) / 15
    seg_mesh = None
    for i in range(15):
        cx = x0 + segw * (i + 0.5)
        if seg_mesh is None:
            m = MB(); r = m.ring([(-(segw - 0.8) / 2, -1.6), ((segw - 0.8) / 2, -1.6), ((segw - 0.8) / 2, 1.6), (-(segw - 0.8) / 2, 1.6)], 0.0); m.face(r, 0)
            o = to_object(m, 'gsLightbar_01', [bpy.data.materials['series7810Gs_lcdSeg_mat']], flip_check=False)
            seg_mesh = o.data
        else:
            o = bpy.data.objects.new('gsLightbar_%02d' % (i + 1), seg_mesh); bpy.context.scene.collection.objects.link(o)
        o.location = Vector((cx, yhb, -2.9)) * 0.001
        o.parent = scr; o.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.view_layer.update()

    # --- UV (jedan sloj, box projekcija) + i3D svojstva
    clip = {'gsHousing': 25.0, 'gsScreen': 15.0, 'gsMountParts': 25.0, 'gsMountSwivel': 25.0, 'gsMountTilt': 25.0, 'gsMountCable': 25.0}
    for o in bpy.data.objects:
        if o.type != 'MESH': continue
        me = o.data
        if o.name.startswith('gsLightbar_'):
            o['i3D_clipDistance'] = 12.0
        else:
            o['i3D_clipDistance'] = clip.get(o.name, 15.0)
        if len(me.uv_layers) == 0:
            uv = me.uv_layers.new(name='UVMap')
            for p in me.polygons:
                n = p.normal; ax = max(range(3), key=lambda i: abs(n[i]))
                for li in p.loop_indices:
                    co = me.vertices[me.loops[li].vertex_index].co
                    u, v = [(co.y, co.z), (co.x, co.z), (co.x, co.y)][ax]
                    uv.data[li].uv = (u * 5.0, v * 5.0)
        bm = bmesh.new(); bm.from_mesh(me)
        for e in bm.edges:
            if len(e.link_faces) == 2 and e.calc_face_angle(0) > math.radians(40): e.smooth = False
        for f in bm.faces: f.smooth = True
        bm.to_mesh(me); bm.free()
        if not o.name.startswith(('gsScreen', 'gsLightbar')):
            # weighted normals: velike ravne plohe dominiraju -> bez gradijenata preko lica
            md = o.modifiers.new('wn', 'WEIGHTED_NORMAL'); md.mode = 'FACE_AREA'; md.weight = 100; md.keep_sharp = True; md.thresh = 0.01
            bpy.context.view_layer.update()
            dg = bpy.context.evaluated_depsgraph_get()
            nm = bpy.data.meshes.new_from_object(o.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
            o.modifiers.remove(md)
            old = o.data; o.data = nm; nm.name = old.name if old.users > 1 else o.name
            if old.users == 0: bpy.data.meshes.remove(old)
            for i, m in enumerate(old.materials if False else []): pass
    if not HIGH:
        # igra: manje draw callova – celik -> steelBlack, kabel spojen u gsMountParts
        st = bpy.data.materials['series7810ExtrasI_steel_mat']; sb = bpy.data.materials['series7810ExtrasI_steelBlack_mat']
        for o in bpy.data.objects:
            if o.type == 'MESH':
                for i, m in enumerate(o.data.materials):
                    if m == st: o.data.materials[i] = sb
        for o in bpy.data.objects:
            if o.type == 'MESH':
                me = o.data; mats = list(me.materials)
                if len(set(mats)) < len(mats):
                    first = {}
                    for i, m in enumerate(mats): first.setdefault(m.name, i)
                    for p in me.polygons: p.material_index = first[mats[p.material_index].name]
        cab = bpy.data.objects['gsMountCable']; mp = bpy.data.objects['gsMountParts']
        bm = bmesh.new(); bm.from_mesh(mp.data); n0 = len(bm.faces)
        cme = cab.data.copy(); off = cab.location - mp.location
        for v in cme.vertices: v.co += off
        bm.from_mesh(cme); bm.faces.ensure_lookup_table()
        mp.data.materials.append(bpy.data.materials['series7810ExtrasI_rubber_mat'])
        ri = len(mp.data.materials) - 1
        for f in list(bm.faces)[n0:]: f.material_index = ri
        bm.to_mesh(mp.data); bm.free(); bpy.data.meshes.remove(cme)
        bpy.data.objects.remove(cab)
    # izbaci neiskoristene materijalne slotove
    for o in bpy.data.objects:
        if o.type != 'MESH': continue
        me = o.data
        used = sorted({p.material_index for p in me.polygons})
        if len(used) < len(me.materials):
            keep = [me.materials[i] for i in used]; remap = {u: k for k, u in enumerate(used)}
            idx = [remap[p.material_index] for p in me.polygons]
            me.materials.clear()
            for m in keep: me.materials.append(m)
            for p, i in zip(me.polygons, idx): p.material_index = i
    # samo jedan UV sloj
    for o in bpy.data.objects:
        if o.type == 'MESH':
            while len(o.data.uv_layers) > 1: o.data.uv_layers.remove(o.data.uv_layers[-1])
            o.data.update()
    bpy.context.view_layer.update()

    # statistika
    tot = 0
    rep = []
    for o in sorted(bpy.data.objects, key=lambda o: o.name):
        if o.type == 'MESH':
            o.data.calc_loop_triangles(); t = len(o.data.loop_triangles); tot += t
            rep.append('%-16s %6d tris  mats=%s  clip=%s' % (o.name, t, [m.name for m in o.data.materials], o.get('i3D_clipDistance')))
    rep.append('UKUPNO %d tris' % tot)
    dc = sum(len(o.data.materials) for o in bpy.data.objects if o.type == 'MESH')
    rep.append('draw callova (subseti) ~%d' % dc)
    # ---- validacija
    err = []
    for o in bpy.data.objects:
        if o.hide_get() or o.hide_viewport or o.hide_render: err.append('skriven: ' + o.name)
        if o.type == 'MESH':
            if len(o.data.uv_layers) != 1: err.append('UV slojeva %d: %s' % (len(o.data.uv_layers), o.name))
            if 'i3D_clipDistance' not in o: err.append('nema clipDistance: ' + o.name)
            used = {p.material_index for p in o.data.polygons}
            if len(used) != len(o.data.materials): err.append('prazan materijal: ' + o.name)
        if o.parent is not None and o != bpy.data.objects['gsTerminalMount']:
            if tuple(round(a, 6) for a in o.rotation_euler) != (0, 0, 0) or tuple(round(a, 6) for a in o.scale) != (1, 1, 1):
                err.append('rot/scale: ' + o.name)
    for c in 'ABCDEFG':
        r = bpy.data.objects['gsRow' + c].matrix_world.translation; k = bpy.data.objects['gsKey' + c].matrix_world.translation
        v = bpy.data.objects['gsVal' + c].matrix_world.translation
        if abs(r.y - k.y) > 1e-5 or abs(v.y - k.y) > 1e-5: err.append('red %s nije u visini tipke (%.4f vs %.4f)' % (c, r.y, k.y))
        rep.append('red %s: sidro Y=%.1f mm, tipka Y=%.1f mm' % (c, r.y * 1000, k.y * 1000))
    rep.append('VALIDACIJA: ' + ('OK' if not err else '; '.join(err)))
    open(OUT.replace('.blend', '_stats.txt'), 'w').write('\n'.join(rep))
    print('\n'.join(rep))
    bpy.ops.wm.save_as_mainfile(filepath=OUT, compress=True)

main()
