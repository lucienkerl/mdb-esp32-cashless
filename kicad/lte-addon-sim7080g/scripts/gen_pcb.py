#!/usr/bin/env python3
"""Generate / route lte-addon-sim7080g.kicad_pcb (KiCad 9 pcbnew API).

    gen_pcb.py place    build the board from design.py, place parts, draw the
                        outline and the RF line, write <name>.dsn for Freerouting
    gen_pcb.py finish   import <name>.ses, add ground pours, stitching vias and
                        silkscreen, fill zones and save

Coordinates are the mainboard's (kicad/mdb_slave_esp32s3-wroom-1u), so the
module's J1 lands on the mainboard's J2 socket. Run inside a KiCad 9
environment (e.g. the kicad/kicad:9.0 docker image).
"""
import json
import math
import os
import sys
import uuid as uuidlib

import pcbnew

sys.path.insert(0, os.path.dirname(__file__))
from design import PARTS, PROJECT  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
PCB = os.path.join(PROJ, PROJECT + ".kicad_pcb")
PRO = os.path.join(PROJ, PROJECT + ".kicad_pro")
DSN = os.path.join(PROJ, "build", PROJECT + ".dsn")
SES = os.path.join(PROJ, "build", PROJECT + ".ses")
FPLIB = os.environ.get("KICAD9_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
NS = uuidlib.UUID("6b1d6a52-7d0e-4f53-9d3e-0a1b2c3d4e5f")


def uid(*key):
    return str(uuidlib.uuid5(NS, "/".join(key)))


def mm(x, y):
    return pcbnew.VECTOR2I(pcbnew.FromMM(x), pcbnew.FromMM(y))


# ---------------------------------------------------------------- outline --
# Mainboard J2 pin n sits at x = 112.470 + 2.54*(n-1), y = 126.754.
HDR_X0, HDR_Y = 112.470376, 126.754043
OUTLINE = [
    (110.9, 125.2), (127.0, 125.2),   # neck, between mainboard J1 (RFID) and J3 (I2C)
    (127.0, 132.4), (144.0, 132.4),   # step clear of J3
    (144.0, 152.5), (94.0, 152.5),    # bottom edge, clear of the screw terminals
    (94.0, 129.2), (110.9, 129.2),    # step clear of J1
]

# --------------------------------------------------------------- placement --
# ref: (x, y, rotation_deg)
U1_C = (120.0, 141.75)
PLACE = {
    "U1": (U1_C[0], U1_C[1], 270),
    # neck: UART level shifters (between the header and the modem)
    "R2": (111.9, 130.6, 90), "Q1": (114.6, 130.6, 0), "R3": (117.3, 130.6, 90),
    "Q2": (120.0, 130.6, 0), "R4": (122.7, 130.6, 90), "R5": (124.9, 130.6, 270),
    # left: SIM holder (card slot facing the west edge), series resistors below
    "J2": (99.76, 141.5, 90),
    "TP3": (95.6, 150.6, 0),
    "R12": (99.5, 150.6, 270), "R13": (101.3, 150.6, 270), "R14": (103.1, 150.6, 270),
    "C7": (104.9, 150.6, 90),
    # left top strip: spacer hole, network LED, detect pull-up
    "H1": (96.3, 132.2, 0),
    "Q4": (100.9, 132.4, 0), "R9": (103.6, 132.4, 90), "R10": (105.3, 132.4, 90),
    "R11": (107.0, 132.4, 90), "D1": (108.6, 132.4, 90),
    "R8": (110.15, 130.9, 90),
    # right: supply link, PWRKEY, bulk, test points
    "R1": (134.2, 134.3, 0), "H2": (141.4, 135.0, 0),
    "Q3": (133.3, 138.5, 0), "R6": (136.0, 138.5, 90), "R7": (137.8, 138.5, 90),
    "TP2": (140.6, 139.6, 0), "TP1": (142.7, 139.6, 0),
    "C4": (132.0, 143.3, 0), "C5": (132.0, 144.9, 0), "C6": (132.0, 146.5, 0),
    "C3": (135.3, 145.0, 90), "C1": (138.3, 145.0, 90), "C2": (141.9, 145.0, 90),
    # RF: pad 32 -> pi match -> U.FL (line drawn in route_rf)
    "C8": (130.8, 149.2, 90), "R15": (133.05, 150.0, 0), "C9": (135.3, 149.2, 90),
    "J3": (138.4, 150.0, 0),
}


def netn(nets, name):
    """Schematic net name: local labels get a '/' prefix, global nets don't."""
    return nets.get("/" + name) or nets[name]


def load_fp(fpid):
    lib, name = fpid.split(":")
    path = os.path.join(PROJ, "lib", "vmflow_lte.pretty") if lib == "vmflow_lte" \
        else os.path.join(FPLIB, lib + ".pretty")
    fp = pcbnew.FootprintLoad(path, name)
    if fp is None:
        raise RuntimeError("footprint not found: " + fpid)
    fp.SetFPID(pcbnew.LIB_ID(lib, name))
    return fp


def write_project():
    """Net classes + design rules live in the project file."""
    def cls(name, clr, w, prio):
        return {"name": name, "clearance": clr, "track_width": w, "via_diameter": 0.6,
                "via_drill": 0.3, "microvia_diameter": 0.3, "microvia_drill": 0.1,
                "diff_pair_width": 0.2, "diff_pair_gap": 0.25, "diff_pair_via_gap": 0.25,
                "wire_width": 6, "bus_width": 12, "line_style": 0,
                "schematic_color": "rgba(0, 0, 0, 0.000)", "pcb_color": "rgba(0, 0, 0, 0.000)",
                "priority": prio}
    pro = {}
    if os.path.exists(PRO):
        try:
            pro = json.load(open(PRO))
        except ValueError:
            pro = {}
    pro.setdefault("meta", {"filename": PROJECT + ".kicad_pro", "version": 3})
    pro["net_settings"] = {
        "classes": [cls("Default", 0.15, 0.2, 2147483647), cls("Power", 0.15, 0.5, 0),
                    cls("RF", 0.3, 0.36, 1)],
        "meta": {"version": 4},
        "net_colors": None,
        "netclass_assignments": None,
        "netclass_patterns": [{"netclass": "Power", "pattern": "*VBAT"},
                              {"netclass": "Power", "pattern": "*+3V3"},
                              {"netclass": "Power", "pattern": "*GND"},
                              {"netclass": "RF", "pattern": "*RF_*"}],
    }
    json.dump(pro, open(PRO, "w"), indent=2)


def schematic_nets():
    """(ref, pin) -> net name, from `kicad-cli sch export netlist` output."""
    path = os.path.join(PROJ, "build", "netlist.net")
    txt = open(path).read()
    out = {}
    for blk in txt.split("(net (code")[1:]:
        name = blk.split('(name "', 1)[1].split('"', 1)[0]
        import re
        for ref, pin in re.findall(r'\(node \(ref "([^"]+)"\) \(pin "([^"]+)"', blk):
            out[(ref, pin)] = name
    return out


def place():
    board = pcbnew.BOARD()
    board.SetCopperLayerCount(4)
    ds = board.GetDesignSettings()
    ds.m_MinClearance = pcbnew.FromMM(0.15)
    ds.m_TrackMinWidth = pcbnew.FromMM(0.15)
    ds.m_ViasMinSize = pcbnew.FromMM(0.5)
    ds.m_MinThroughDrill = pcbnew.FromMM(0.3)
    ds.m_CopperEdgeClearance = pcbnew.FromMM(0.3)
    ds.m_HoleClearance = pcbnew.FromMM(0.2)
    ds.m_HoleToHoleMin = pcbnew.FromMM(0.25)
    ds.m_SolderMaskMinWidth = pcbnew.FromMM(0.1)
    # the stock U.FL footprint opens the mask across its own pads
    ds.m_AllowSoldermaskBridgesInFPs = True
    # inner layers are ground planes; Freerouting only routes on F.Cu / B.Cu
    board.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    board.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)

    nets = {}
    sch = schematic_nets()

    def net(name):
        if name not in nets:
            ni = pcbnew.NETINFO_ITEM(board, name)
            board.Add(ni)
            nets[name] = ni
        return nets[name]

    for ref, lib_id, value, fpid, pinnets, extra in PARTS:
        if ref.startswith("#"):
            continue
        fp = load_fp(fpid)
        fp.SetReference(ref)
        fp.SetValue(value)
        fp.SetPath(pcbnew.KIID_PATH("/" + uid(ref, "sym")))
        if extra.get("dnp"):
            fp.SetDNP(True)
        if ref in ("U1", "J2"):
            # tiny shield tabs / LGA ground pads: solid to the pour, no spokes
            fp.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)
        board.Add(fp)
        if ref == "J1":
            # male header on the bottom, pin n exactly over mainboard J2 pin n
            fp.SetPosition(mm(HDR_X0, HDR_Y))
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
            for ang in (0, 90, 180, 270):
                fp.SetOrientationDegrees(ang)
                p6 = fp.FindPadByNumber("6").GetPosition()
                if abs(pcbnew.ToMM(p6.x) - (HDR_X0 + 5 * 2.54)) < 0.01 and \
                        abs(pcbnew.ToMM(p6.y) - HDR_Y) < 0.01:
                    break
            else:
                raise RuntimeError("could not align J1 with the mainboard J2")
        else:
            x, y, rot = PLACE[ref]
            fp.SetPosition(mm(x, y))
            fp.SetOrientationDegrees(rot)
        for pad in fp.Pads():
            n = sch.get((ref, pad.GetNumber()))
            if n is None and pinnets.get(pad.GetNumber()):
                raise RuntimeError("net mismatch %s.%s" % (ref, pad.GetNumber()))
            if n:
                pad.SetNet(net(n))

    # board outline
    pts = OUTLINE + [OUTLINE[0]]
    for a, b in zip(pts, pts[1:]):
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(pcbnew.SHAPE_T_SEGMENT)
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(pcbnew.FromMM(0.1))
        s.SetStart(mm(*a))
        s.SetEnd(mm(*b))
        board.Add(s)

    # inner ground planes (Freerouting connects GND pads to them with vias)
    for layer in (pcbnew.In1_Cu, pcbnew.In2_Cu):
        add_zone(board, netn(nets, "GND"), layer, OUTLINE, prio=0)

    route_rf(board, nets)
    # ground anchor for the SIM holder's shield tabs between holder and modem
    sh = min((p for p in board.FindFootprintByReference("J2").Pads() if p.GetNumber() == "SH"),
             key=lambda p: (pcbnew.ToMM(p.GetPosition().x) - 108.55) ** 2 + (pcbnew.ToMM(p.GetPosition().y) - 143.7) ** 2)
    shx, shy = pcbnew.ToMM(sh.GetPosition().x), pcbnew.ToMM(sh.GetPosition().y)
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(mm(107.0, 145.6))
    v.SetWidth(pcbnew.FromMM(0.6))
    v.SetDrill(pcbnew.FromMM(0.3))
    v.SetNet(netn(nets, "GND"))
    v.SetLocked(True)
    board.Add(v)
    track(board, netn(nets, "GND"), [(107.0, 145.6), (shx, shy)], 0.3)
    pcbnew.SaveBoard(PCB, board)
    write_project()


def add_zone(board, netinfo, layer, poly, prio=0, clearance=0.25):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(netinfo)
    z.SetAssignedPriority(prio)
    z.SetLocalClearance(pcbnew.FromMM(clearance))
    z.SetMinThickness(pcbnew.FromMM(0.2))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    z.SetThermalReliefGap(pcbnew.FromMM(0.3))
    z.SetThermalReliefSpokeWidth(pcbnew.FromMM(0.4))
    ol = z.Outline()
    ol.NewOutline()
    for x, y in poly:
        ol.Append(pcbnew.FromMM(x), pcbnew.FromMM(y))
    board.Add(z)
    return z


def pad_xy(board, ref, num):
    p = board.FindFootprintByReference(ref).FindPadByNumber(num).GetPosition()
    return pcbnew.ToMM(p.x), pcbnew.ToMM(p.y)


def track(board, netinfo, pts, width, layer=pcbnew.F_Cu):
    for a, b in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(mm(*a))
        t.SetEnd(mm(*b))
        t.SetWidth(pcbnew.FromMM(width))
        t.SetLayer(layer)
        t.SetNet(netinfo)
        t.SetLocked(True)
        board.Add(t)


def route_rf(board, nets):
    """50 ohm-ish line (0.36 mm over In1 GND, JLC 4-layer 7628 stackup)."""
    w = 0.36
    p32 = pad_xy(board, "U1", "32")
    r1 = pad_xy(board, "R15", "1")
    r2 = pad_xy(board, "R15", "2")
    c8 = pad_xy(board, "C8", "1")
    c9 = pad_xy(board, "C9", "1")
    j = pad_xy(board, "J3", "1")
    y_low = 150.95
    track(board, netn(nets, "RF_ANT"), [p32, (p32[0], y_low), (127.0, y_low),
                                  (127.0 + (y_low - r1[1]), r1[1]), r1], w)
    track(board, netn(nets, "RF_ANT"), [(c8[0], r1[1]), c8], w)
    track(board, netn(nets, "RF_UFL"), [r2, j], w)
    track(board, netn(nets, "RF_UFL"), [(c9[0], r2[1]), c9], w)


def finish():
    board = pcbnew.LoadBoard(PCB)
    if os.path.exists(SES):
        ok = pcbnew.ImportSpecctraSES(board, SES)
        print("SES import:", ok)
    gnd = board.FindNet("GND") or board.FindNet("/GND")
    # outer ground pours (copper keeps 0.3 mm from the RF line via its net class)
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        add_zone(board, gnd, layer, OUTLINE, prio=1)
    add_stitching(board, gnd)
    tidy_refs(board)
    add_silk(board)
    filler = pcbnew.ZONE_FILLER(board)
    filler.Fill(board.Zones())
    pcbnew.SaveBoard(PCB, board)


def add_stitching(board, gnd):
    """Ground vias along both sides of the RF line and around the outline."""
    pts = [(126.2, 151.95), (128.0, 151.95), (129.8, 151.6), (131.8, 151.6), (134.2, 151.6),
           (136.0, 151.6), (128.6, 149.2), (132.4, 148.4), (134.0, 148.3), (136.4, 148.0)]
    for x, y in pts:
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(mm(x, y))
        v.SetWidth(pcbnew.FromMM(0.5))
        v.SetDrill(pcbnew.FromMM(0.3))
        v.SetNet(gnd)
        board.Add(v)


def text(board, s, x, y, size=0.8, layer=pcbnew.F_SilkS, rot=0, bold=False):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetPosition(mm(x, y))
    t.SetLayer(layer)
    t.SetTextSize(pcbnew.VECTOR2I(pcbnew.FromMM(size), pcbnew.FromMM(size)))
    t.SetTextThickness(pcbnew.FromMM(size * 0.15))
    t.SetTextAngleDegrees(rot)
    t.SetBold(bold)
    if layer in (pcbnew.B_SilkS,):
        t.SetMirrored(True)
    board.Add(t)


def tidy_refs(board):
    """Small parts carry no silkscreen designator (too dense); the
    assembly drawing (F.Fab) and the interactive BOM show them."""
    for fp in board.GetFootprints():
        ref = fp.Reference()
        name = fp.GetReference()
        if name != "J1":
            ref.SetVisible(False)
        else:
            ref.SetTextSize(pcbnew.VECTOR2I(pcbnew.FromMM(0.8), pcbnew.FromMM(0.8)))
            ref.SetTextThickness(pcbnew.FromMM(0.12))


def add_silk(board):
    T = pcbnew.F_SilkS
    B = pcbnew.B_SilkS
    text(board, "LTE", 135.5, 147.3, 0.8, layer=T)
    text(board, "SIM", 96.0, 135.6, 0.8, layer=T)
    text(board, "VB", 140.6, 141.3, 0.8, layer=T)
    text(board, "ST", 142.7, 141.3, 0.8, layer=T)
    text(board, "G", 95.6, 149.0, 0.8, layer=T)
    text(board, "NET", 106.0, 134.6, 0.8, layer=T)
    # bottom: title + header pin functions (readable from the bottom side)
    text(board, "VMflow LTE SIM7080G", 104.0, 137.0, 0.9, layer=B, bold=True)
    text(board, "rev 1.0  to mainboard J2", 104.0, 138.6, 0.8, layer=B)
    for i, lab in enumerate(["42", "41", "40", "39", "G", "3V3"]):
        text(board, lab, HDR_X0 + 2.54 * i, 129.6, 0.8, layer=B)

if __name__ == "__main__":
    os.makedirs(os.path.join(PROJ, "build"), exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "place"
    if cmd == "place":
        place()
        board = pcbnew.LoadBoard(PCB)
        print("DSN export:", pcbnew.ExportSpecctraDSN(board, DSN))
    elif cmd == "finish":
        finish()
    else:
        raise SystemExit("usage: gen_pcb.py place|finish")
