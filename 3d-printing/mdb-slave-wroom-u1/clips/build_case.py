"""WROOM-1U MDB slave enclosure - FreeCAD 1.x script (Part workbench). Units: mm.

Run from this folder:
  "C:\\Program Files\\FreeCAD 1.1\\bin\\freecadcmd.exe" build_case.py

Reads the board STEP from STEP_PATH (KiCad export: board centred on the origin,
bottom face at z=0) and places the board at PCB_Z inside the base.

Writes base.step/.stl and lid.step/.stl next to this script. The lid STL is flipped
so its outer face lies on the print bed. Geometry checks (solid validity, overlap
between parts, collisions with the board) are printed to stdout.
"""
import json
import os

import FreeCAD as App
import Import
import MeshPart
import Part

V = App.Vector
try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = os.getcwd()
STEP_PATH = os.path.join(HERE, "..", "pcb_wroom-u1.step")      # board model, shared by both variants

# ---------------------------------------------------------------- variant
LID_SCREWS = False                      # True: clips + optional M2.5 screws, False: clips only
CLIP_X = (-64.5, 60.0)                  # clip positions on north and south walls

# ---------------------------------------------------------------- parameters
WALL = 2.0            # wall thickness
FLOOR = 2.0           # floor thickness
LID = 2.0             # lid thickness
GAP = 0.6             # board to wall clearance
STANDOFF = 5.0        # standoff height (through-hole leads reach -2.9 mm)
PCB_Z = FLOOR + STANDOFF
PCB_T = 1.52
TOP_CLEAR = 1.4       # clearance above the tallest part (relays, 17.6 mm)
INSERT_BORE = 3.3     # M2.5 x 5 x OD3.5 heat insert, validated on a test coupon
INSERT_DEPTH = 5.6
LID_SCREW = 2.9       # M2.5 clearance hole in the lid
FIT = 0.25            # lid lip to wall clearance
TERM_W = 4.0          # terminal wire window width and lid screwdriver hole diameter. Poles sit
                      # 5.08 mm apart: 4.0 leaves 1.08 mm webs, two lines of a 0.4 mm nozzle
                      # (4.8 left 0.28 mm, which the slicer drops or prints as loose strands)

BOARD_X, BOARD_Y = 74.91, 19.25
PCB_HOLES = [(-71.414936, -15.75), (-71.414936, 15.75), (41.4757, -15.7906), (41.4857, 14.7496)]

X0, X1 = -75.6, BOARD_X + GAP          # inner cavity (USB-C sticks out to -75.42)
Y0, Y1 = -(BOARD_Y + 0.5), BOARD_Y + 0.5
H = PCB_Z + 17.6 + TOP_CLEAR           # base height (top of the walls)


# WJ500V terminal blocks: pole centres (board frame). side = wall the wire goes through.
def poles(first, other, side, axis="x"):
    return [((first + i * 5.08, other) if axis == "x" else (other, first + i * 5.08), side) for i in range(3)]


TERMINALS = []
for xf in (-57.79, -42.23, -26.68, -11.14):              # P4 P5 P6 P3 (south)
    TERMINALS += poles(xf, -14.30, "S")
for xf in (9.09, 24.63):                                  # P2 P1 (north)
    TERMINALS += poles(xf, 14.30, "N")
for yf in (-13.75, 2.74):                                 # P8 P9 (east)
    TERMINALS += poles(yf, 70.06, "E", axis="y")
WIRE_Z = (3.08 - 0.6, 9.32 + 0.6)                         # wire entry height, board frame

MDB = (10.04, 24.04, -1.9, 12.3)                          # x0 x1 z0 z1 (board frame)
USB_C = (0.38, 2.78)                                      # centre y, z (board frame)
LEDS = [(-47.76, -3.43)]                                  # WS2812B-2121 "LED D0"
ANTENNA_X = -46.0                                         # U.FL cable slot, north wall
UART_X, UART_W = -33.15, 8.0                              # J1 UART debug cable slot, north wall
SCREW_BOSSES = ([(x, s * (Y1 + WALL + 2.2)) for x in (-73.0, 73.0) for s in (-1, 1)]
                if LID_SCREWS else [])


def box(x0, x1, y0, y1, z0, z1):
    return Part.makeBox(x1 - x0, y1 - y0, z1 - z0, V(x0, y0, z0))


def _fillet(b, r, axis):
    edges = [e for e in b.Edges if abs(getattr(e.Vertexes[0].Point - e.Vertexes[1].Point, axis)) > 1e-6]
    return b.makeFillet(r, edges)


def rbox(x0, x1, y0, y1, z0, z1, r):
    """Box with rounded vertical edges."""
    r = min(r, (x1 - x0) / 2 - 0.01, (y1 - y0) / 2 - 0.01)
    return _fillet(box(x0, x1, y0, y1, z0, z1), r, "z")


def cyl(x, y, r, z0, z1):
    return Part.makeCylinder(r, z1 - z0, V(x, y, z0))


def wall_window(side, a0, a1, z0, z1, r=0.8):
    """Through-hole in a wall. a = x (north/south walls) or y (east/west walls)."""
    r = min(r, (a1 - a0) / 2 - 0.01, (z1 - z0) / 2 - 0.01)
    if side == "S":
        return _fillet(box(a0, a1, Y0 - WALL - 1, Y0 + 1, z0, z1), r, "y")
    if side == "N":
        return _fillet(box(a0, a1, Y1 - 1, Y1 + WALL + 1, z0, z1), r, "y")
    if side == "E":
        return _fillet(box(X1 - 1, X1 + WALL + 1, a0, a1, z0, z1), r, "x")
    return _fillet(box(X0 - WALL - 1, X0 + 1, a0, a1, z0, z1), r, "x")


def insert_cut(shape, x, y, top, diam=INSERT_BORE):
    bore = cyl(x, y, diam / 2, top - INSERT_DEPTH, top + 0.1)
    lead = Part.makeCone(diam / 2, diam / 2 + 0.4, 0.4, V(x, y, top - 0.4))
    return shape.cut(bore.fuse(lead))


def boss_shape(x, y, z0, z1):
    """External screw boss joined to the wall."""
    yw = Y1 + WALL - 0.5 if y > 0 else Y0 - WALL + 0.5
    return cyl(x, y, 3.4, z0, z1).fuse(box(x - 3.4, x + 3.4, min(y, yw), max(y, yw), z0, z1))


# ---------------------------------------------------------------- base
OX0, OX1, OY0, OY1 = X0 - WALL, X1 + WALL, Y0 - WALL, Y1 + WALL
base = rbox(OX0, OX1, OY0, OY1, 0, H, 3.0).cut(rbox(X0, X1, Y0, Y1, FLOOR, H + 1, 1.0))

for x, y in PCB_HOLES:                                    # board standoffs + inserts
    base = insert_cut(base.fuse(cyl(x, y, 3.2, FLOOR - 0.1, PCB_Z)), x, y, PCB_Z)

for x, y in SCREW_BOSSES:                                 # lid screw bosses + inserts
    base = insert_cut(base.fuse(boss_shape(x, y, 0, H)), x, y, H)

# Mounting ears (short ends): solid plate, 10 x 4.5 slot (M4 screw) + 2 zip-tie slots.
# No zip-tie tunnel: a hollow ear squeezes when the M4 screw is tightened, and the tie
# simply goes down one slot and back up the other.
EAR_T, EAR_L = 4.0, 20.0
for sgn, xw in ((-1, OX0), (1, OX1)):
    xc = xw + sgn * EAR_L / 2
    xa, xb = sorted((xw - sgn * 2, xw + sgn * EAR_L))
    ear = rbox(xa, xb, -16, 16, 0, EAR_T, 3.0)
    ear = ear.cut(box(xc - 2.25, xc + 2.25, -2.75, 2.75, -1, EAR_T + 1)
                  .fuse([cyl(xc, -2.75, 2.25, -1, EAR_T + 1), cyl(xc, 2.75, 2.25, -1, EAR_T + 1)]))
    for y in (-11.0, 11.0):
        ear = ear.cut(box(xc - 4.5, xc + 4.5, y - 1.6, y + 1.6, -1, EAR_T + 1))
    base = base.fuse(ear)

cuts = []
# USB-C: 12.8 x 7.2, room for an overmoulded plug
cuts.append(wall_window("W", USB_C[0] - 6.4, USB_C[0] + 6.4,
                        PCB_Z + USB_C[1] - 3.6, PCB_Z + USB_C[1] + 3.6, 2.4))
# MDB Mini-Fit 2x3 (plug + latch)
cuts.append(wall_window("S", MDB[0] - 0.8, MDB[1] + 0.8, PCB_Z + PCB_T + 0.3, PCB_Z + MDB[3] + 2.0, 1.0))
# Terminal block wire entries (one window per pole)
for (px, py), side in TERMINALS:
    a = px if side in "NS" else py
    cuts.append(wall_window(side, a - TERM_W / 2, a + TERM_W / 2, PCB_Z + WIRE_Z[0], PCB_Z + WIRE_Z[1], 1.0))
# Antenna: 3 x 2 mm slot at the top of the north wall, under the lid
cuts.append(box(ANTENNA_X - 1.5, ANTENNA_X + 1.5, Y1 - 1, Y1 + WALL + 1, H - 2.0, H + 1))
# UART debug wires: 8 x 2 mm slot at the top of the north wall, above J1
cuts.append(box(UART_X - UART_W / 2, UART_X + UART_W / 2, Y1 - 1, Y1 + WALL + 1, H - 2.0, H + 1))
# Low ventilation: 1.6 x 3.4 vertical slots below the board, north and south walls
for x in [i * 5.0 for i in range(-14, 15)]:
    if any(abs(x - bx) < 5 for bx, _ in SCREW_BOSSES):
        continue
    for side in "NS":
        cuts.append(wall_window(side, x - 0.8, x + 0.8, FLOOR + 0.8, PCB_Z - 0.8, 0.7))
# Clip windows
CLIP_W, CLIP_Z0, CLIP_Z1 = 8.0, H - 8.0, H - 5.6
for x in CLIP_X:
    for side in "NS":
        cuts.append(wall_window(side, x - CLIP_W / 2 - 0.4, x + CLIP_W / 2 + 0.4, CLIP_Z0, CLIP_Z1, 0.4))
for c in cuts:
    base = base.cut(c)
base = base.removeSplitter()

# ---------------------------------------------------------------- lid
lid = rbox(OX0, OX1, OY0, OY1, H, H + LID, 3.0)
for x, y in SCREW_BOSSES:
    lid = lid.fuse(boss_shape(x, y, H, H + LID))
LIP_D, LIP_T = 2.5, 1.6
lip = rbox(X0 + FIT, X1 - FIT, Y0 + FIT, Y1 - FIT, H - LIP_D, H + 0.01, 1.0).cut(
    rbox(X0 + FIT + LIP_T, X1 - FIT - LIP_T, Y0 + FIT + LIP_T, Y1 - FIT - LIP_T, H - LIP_D - 1, H + 1, 0.5))
lip = lip.cut(box(ANTENNA_X - 2.0, ANTENNA_X + 2.0, Y1 - 3, Y1 + 1, H - LIP_D - 1, H + 1))
lip = lip.cut(box(UART_X - UART_W / 2 - 0.5, UART_X + UART_W / 2 + 0.5, Y1 - 3, Y1 + 1, H - LIP_D - 1, H + 1))
for x in CLIP_X:                                  # lip relief around the clip tabs
    for yw in (Y0, Y1):
        lip = lip.cut(box(x - CLIP_W / 2 - 1.0, x + CLIP_W / 2 + 1.0, yw - 3, yw + 3, H - LIP_D - 1, H + 1))
lid = lid.fuse(lip)

# Clips: 8 x 1.2 mm tab, ~8 mm free length, 0.6 mm ramped catch.
CLIP_T, BUMP = 1.2, 0.6
for x in CLIP_X:
    for sgn, yw in ((-1, Y0), (1, Y1)):
        y_out = yw - sgn * FIT
        y_in = y_out - sgn * CLIP_T
        tab = box(x - CLIP_W / 2, x + CLIP_W / 2, min(y_in, y_out), max(y_in, y_out), CLIP_Z0 - 0.3, H + 0.01)
        zc, zb = CLIP_Z1 - 0.3, CLIP_Z0 - 0.1
        pts = [V(x - CLIP_W / 2, y_out - sgn * 0.01, zb), V(x - CLIP_W / 2, y_out + sgn * BUMP, zc),
               V(x - CLIP_W / 2, y_out - sgn * 0.01, zc), V(x - CLIP_W / 2, y_out - sgn * 0.01, zb)]
        tri = Part.Face(Part.makePolygon(pts)).extrude(V(CLIP_W, 0, 0))
        lid = lid.fuse(tab).fuse(tri)

lid_cuts = []
for x, y in SCREW_BOSSES:
    lid_cuts.append(cyl(x, y, LID_SCREW / 2, H - 1, H + LID + 1))
for (px, py), side in TERMINALS:                  # screwdriver access to terminal screws
    lid_cuts.append(cyl(px, py, TERM_W / 2, H - 1, H + LID + 1))
for x, y in LEDS:                                 # LED window
    lid_cuts.append(cyl(x, y, 2.0, H - 1, H + LID + 1))
# High ventilation: 1.6 x 12 slots above the relays and the centre area
for x in [46.0 + i * 3.2 for i in range(6)] + [-24.0 + i * 3.2 for i in range(8)]:
    lid_cuts.append(box(x - 0.8, x + 0.8, -6.0, 6.0, H - 1, H + LID + 1))
for c in lid_cuts:
    lid = lid.cut(c)
lid = lid.removeSplitter()

# ---------------------------------------------------------------- checks
doc = App.newDocument("pcb")
Import.insert(STEP_PATH, doc.Name)
root = [o for o in doc.Objects if o.TypeId == "App::Part" and not o.InList][0]
pcb_solids = []
for o in root.Group:
    if hasattr(o, "Shape") and not o.Shape.isNull():
        for s in o.Shape.Solids:
            s = s.copy()
            s.translate(V(0, 0, PCB_Z))
            pcb_solids.append((o.Label, s))

collisions = []
for name, part in (("base", base), ("lid", lid)):
    for label, s in pcb_solids:
        if not part.BoundBox.intersect(s.BoundBox):
            continue
        v = part.common(s).Volume
        if v > 0.01:
            collisions.append({"part": name, "component": label, "volume_mm3": round(v, 3)})

checks = {}
for name, part in (("base", base), ("lid", lid)):
    b = part.BoundBox
    checks[name] = {"valid": part.isValid(), "solids": len(part.Solids), "volume_mm3": round(part.Volume, 1),
                    "size_mm": [round(b.XLength, 2), round(b.YLength, 2), round(b.ZLength, 2)]}
checks["base_lid_overlap_mm3"] = round(base.common(lid).Volume, 3)
checks["pcb_collisions"] = collisions
checks["base_height_mm"] = round(H, 2)
if SCREW_BOSSES:
    # Clip windows must stay reachable from outside: no screw boss in front of them.
    checks["clip_boss_min_gap_mm"] = round(min(
        abs(cx - bx) - (CLIP_W / 2 + 0.4) - 3.4 for cx in CLIP_X for bx, _ in SCREW_BOSSES), 2)
    assert checks["clip_boss_min_gap_mm"] > 0.5, checks["clip_boss_min_gap_mm"]


# ---------------------------------------------------------------- export
def stl(shape, path):
    m = MeshPart.meshFromShape(Shape=shape, LinearDeflection=0.03, AngularDeflection=0.2)
    m.write(path)
    return bool(m.isSolid() and not m.hasNonManifolds())


base.exportStep(os.path.join(HERE, "base.step"))
lid.exportStep(os.path.join(HERE, "lid.step"))
checks["base"]["stl_ok"] = stl(base, os.path.join(HERE, "base.stl"))
lid_print = lid.copy()
lid_print.rotate(V(0, 0, 0), V(1, 0, 0), 180)     # outer face on the print bed
lid_print.translate(V(0, 0, -lid_print.BoundBox.ZMin))
checks["lid"]["stl_ok"] = stl(lid_print, os.path.join(HERE, "lid.stl"))

print(json.dumps(checks, indent=2))
