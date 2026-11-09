#!/usr/bin/env python3
"""Small grid router for the LTE add-on (2 signal layers, inner layers = GND).

Routes every non-GND net of the placed board on F.Cu/B.Cu with an A* search
on a 0.05 mm grid (45 degree moves, vias between the outer layers), then fans
GND pads out to the inner planes with short stubs and vias. Pre-routed (locked)
tracks such as the RF line are kept and treated as obstacles.

Run inside KiCad 9 (pcbnew + numpy):  python3 scripts/route.py
"""
import heapq
import math
import os
import sys

import numpy as np
import pcbnew

sys.path.insert(0, os.path.dirname(__file__))
from design import PROJECT  # noqa: E402
from gen_pcb import OUTLINE, PCB  # noqa: E402

G = 0.05                      # grid pitch, mm
CLR = 0.15                    # copper clearance used by the router (rule: 0.15)
MARGIN = 0.06                 # extra margin for grid quantisation
EDGE = 0.3                    # copper to board edge
VIA_D, VIA_DRILL = 0.6, 0.3
VIA_COST = 30.0               # in grid steps
WIDTH = {"/VBAT": 0.5, "VBAT": 0.5, "/+3V3": 0.5, "+3V3": 0.5}
DEFAULT_W = 0.2
GND_W = 0.3
RF_EXTRA = 0.2                # RF net class clearance is 0.3 mm (+ margin)
ORDER = ["/" + n for n in [
    "+3V3", "ESP_TX", "ESP_RX", "MDM_TXD", "MDM_RXD", "Q1_B", "Q2_B", "VDD_EXT",
    "DETECT", "PWRKEY_CTL", "VBAT",
    "SIM_VDD", "SIM_RST", "SIM_CLK", "SIM_DATA", "SIM_RST_C", "SIM_CLK_C", "SIM_DATA_C",
    "PWRKEY", "Q3_B", "NETLIGHT", "Q4_B", "LED_K", "LED_A", "STATUS"]]
GND = "GND"

X0 = min(p[0] for p in OUTLINE) - 0.5
Y0 = min(p[1] for p in OUTLINE) - 0.5
NX = int((max(p[0] for p in OUTLINE) + 0.5 - X0) / G) + 1
NY = int((max(p[1] for p in OUTLINE) + 0.5 - Y0) / G) + 1
LAYERS = [pcbnew.F_Cu, pcbnew.B_Cu]

XS = X0 + np.arange(NX) * G
YS = Y0 + np.arange(NY) * G


def to_mm(v):
    return v / 1e6


def cell_xy(i, j):
    return float(X0 + i * G), float(Y0 + j * G)


# ------------------------------------------------------------ rasterising --
def fill_poly(mask, pts):
    """Even-odd scanline fill of polygon `pts` (mm) into bool grid mask[j, i]."""
    n = len(pts)
    ys = [p[1] for p in pts]
    j0 = max(0, int((min(ys) - Y0) / G) - 1)
    j1 = min(NY - 1, int((max(ys) - Y0) / G) + 1)
    for j in range(j0, j1 + 1):
        y = Y0 + j * G
        xs = []
        for k in range(n):
            (xa, ya), (xb, yb) = pts[k], pts[(k + 1) % n]
            if (ya <= y < yb) or (yb <= y < ya):
                xs.append(xa + (y - ya) * (xb - xa) / (yb - ya))
        xs.sort()
        for a, b in zip(xs[0::2], xs[1::2]):
            i0 = max(0, int(math.ceil((a - X0) / G)))
            i1 = min(NX - 1, int(math.floor((b - X0) / G)))
            if i1 >= i0:
                mask[j, i0:i1 + 1] = True


def poly_points(sps):
    out = []
    for o in range(sps.OutlineCount()):
        ol = sps.Outline(o)
        out.append([(to_mm(ol.CPoint(k).x), to_mm(ol.CPoint(k).y)) for k in range(ol.PointCount())])
    return out


def capsule(mask, a, b, r):
    """Cells within r of segment a-b."""
    xa, ya = a
    xb, yb = b
    i0 = max(0, int((min(xa, xb) - r - X0) / G) - 1)
    i1 = min(NX - 1, int((max(xa, xb) + r - X0) / G) + 1)
    j0 = max(0, int((min(ya, yb) - r - Y0) / G) - 1)
    j1 = min(NY - 1, int((max(ya, yb) + r - Y0) / G) + 1)
    if i1 < i0 or j1 < j0:
        return
    X, Y = np.meshgrid(XS[i0:i1 + 1], YS[j0:j1 + 1])
    dx, dy = xb - xa, yb - ya
    L2 = dx * dx + dy * dy
    if L2 == 0:
        d2 = (X - xa) ** 2 + (Y - ya) ** 2
    else:
        t = np.clip(((X - xa) * dx + (Y - ya) * dy) / L2, 0, 1)
        d2 = (X - xa - t * dx) ** 2 + (Y - ya - t * dy) ** 2
    mask[j0:j1 + 1, i0:i1 + 1] |= d2 <= r * r


def dilate(mask, r):
    if r <= 0:
        return mask.copy()
    k = int(math.ceil(r / G))
    out = mask.copy()
    for dj in range(-k, k + 1):
        for di in range(-k, k + 1):
            if (di == 0 and dj == 0) or (di * di + dj * dj) * G * G > r * r:
                continue
            src = mask[max(0, -dj):NY - max(0, dj), max(0, -di):NX - max(0, di)]
            out[max(0, dj):NY - max(0, -dj), max(0, di):NX - max(0, -di)] |= src
    return out


# --------------------------------------------------------------- the board --
class Router:
    def __init__(self, board):
        self.b = board
        self.inside = np.zeros((NY, NX), bool)
        fill_poly(self.inside, OUTLINE)
        self.outside = ~self.inside
        # copper per layer: dict net -> mask ; "pads" separately for via rules
        self.cu = [dict(), dict()]
        self.routed = [dict(), dict()]      # tracks/vias only, per net
        self.padmask = [np.zeros((NY, NX), bool), np.zeros((NY, NX), bool)]
        self.holes = np.zeros((NY, NX), bool)
        for fp in board.GetFootprints():
            for pad in fp.Pads():
                name = pad.GetNetname() or "~nc~%s%s" % (fp.GetReference(), pad.GetNumber())
                for li, layer in enumerate(LAYERS):
                    if not pad.IsOnLayer(layer):
                        continue
                    m = np.zeros((NY, NX), bool)
                    for pts in poly_points(pad.GetEffectivePolygon(layer, pcbnew.ERROR_OUTSIDE)):
                        fill_poly(m, pts)
                    self._add(li, name, m)
                    self.padmask[li] |= m
                if pad.HasHole() or pad.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH:
                    p = pad.GetPosition()
                    r = to_mm(max(pad.GetDrillSize().x, pad.GetDrillSize().y)) / 2
                    h = np.zeros((NY, NX), bool)
                    capsule(h, (to_mm(p.x), to_mm(p.y)), (to_mm(p.x), to_mm(p.y)), r)
                    self.holes |= h
                    if pad.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH:
                        for li in (0, 1):
                            self._add(li, "~hole~", h)
        for t in board.GetTracks():
            self.add_item(t)
        # footprint rule areas (e.g. the U.FL keep-out): no tracks, no vias
        for fp in board.GetFootprints():
            for z in fp.Zones():
                if not z.GetIsRuleArea():
                    continue
                m = np.zeros((NY, NX), bool)
                for pts in poly_points(z.Outline()):
                    fill_poly(m, pts)
                for li, layer in enumerate(LAYERS):
                    if z.IsOnLayer(layer):
                        self._add(li, "~keepout~", m)
                self.holes |= m

    def _add(self, li, net, m):
        if net in self.cu[li]:
            self.cu[li][net] |= m
        else:
            self.cu[li][net] = m.copy()

    def add_item(self, t):
        net = t.GetNetname()
        if t.GetClass() == "PCB_VIA":
            p = t.GetPosition()
            m = np.zeros((NY, NX), bool)
            c = (to_mm(p.x), to_mm(p.y))
            capsule(m, c, c, to_mm(t.GetWidth(pcbnew.F_Cu)) / 2)
            for li in (0, 1):
                self._add(li, net, m)
                self._routed(li, net, m)
            h = np.zeros((NY, NX), bool)
            capsule(h, c, c, to_mm(t.GetDrillValue()) / 2)
            self.holes |= h
        else:
            li = LAYERS.index(t.GetLayer())
            m = np.zeros((NY, NX), bool)
            a = (to_mm(t.GetStart().x), to_mm(t.GetStart().y))
            b = (to_mm(t.GetEnd().x), to_mm(t.GetEnd().y))
            capsule(m, a, b, to_mm(t.GetWidth()) / 2)
            self._add(li, net, m)
            self._routed(li, net, m)

    def _routed(self, li, net, m):
        if net in self.routed[li]:
            self.routed[li][net] |= m
        else:
            self.routed[li][net] = m.copy()

    def other(self, li, net, rf=None):
        """Copper of all other nets; rf=True/False selects only RF / non-RF nets."""
        m = np.zeros((NY, NX), bool)
        for n, mm_ in self.cu[li].items():
            if n != net and (rf is None or ("RF_" in n) == rf):
                m |= mm_
        return m

    # ---- search -------------------------------------------------------------
    def masks(self, net, w):
        r = CLR + w / 2 + MARGIN
        block = []
        for li in (0, 1):
            b = dilate(self.other(li, net, rf=False), r) | dilate(self.other(li, net, rf=True), r + RF_EXTRA) \
                | dilate(self.outside, EDGE + w / 2 + MARGIN)
            block.append(b)
        rv = CLR + VIA_D / 2 + MARGIN
        via_ok = ~(dilate(self.other(0, net), rv) | dilate(self.other(1, net), rv)
                   | dilate(self.other(0, net, rf=True), rv + RF_EXTRA)
                   | dilate(self.padmask[0] | self.padmask[1], VIA_D / 2 + 0.05)
                   | dilate(self.holes, 0.25 + VIA_DRILL / 2 + MARGIN)
                   | dilate(self.outside, EDGE + VIA_D / 2 + MARGIN))
        return block, via_ok

    def astar(self, sources, targets, block, via_ok, max_expand=2_000_000):
        """sources/targets: bool arrays [2, NY, NX]."""
        tgt_idx = np.argwhere(targets)
        if len(tgt_idx) == 0:
            return None
        ty, tx = tgt_idx[:, 1].mean(), tgt_idx[:, 2].mean()
        tspan = max(np.ptp(tgt_idx[:, 1]), np.ptp(tgt_idx[:, 2])) / 2

        def h(j, i):
            dj, di = abs(j - ty), abs(i - tx)
            return max(0.0, max(dj, di) + 0.414 * min(dj, di) - tspan)

        openh = []
        g = {}
        came = {}
        for li, j, i in np.argwhere(sources):
            s = (int(li), int(j), int(i))
            g[s] = 0.0
            heapq.heappush(openh, (h(j, i), 0.0, s))
        moves = [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
                 (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414)]
        n = 0
        while openh:
            f, gc, s = heapq.heappop(openh)
            if gc > g.get(s, 1e18):
                continue
            li, j, i = s
            if targets[li, j, i]:
                path = [s]
                while path[-1] in came:
                    path.append(came[path[-1]])
                return path[::-1]
            n += 1
            if n > max_expand:
                return None
            prev = came.get(s)
            for dj, di, c in moves:
                jj, ii = j + dj, i + di
                if not (0 <= jj < NY and 0 <= ii < NX) or block[li][jj, ii]:
                    continue
                if dj and di and (block[li][j, ii] or block[li][jj, i]):
                    continue
                cost = c
                if prev is not None and prev[0] == li and (j - prev[1], i - prev[2]) != (dj, di):
                    cost += 0.3          # discourage wiggles
                if li == 1:
                    cost *= 1.15         # prefer the top layer
                ns = (li, jj, ii)
                ng = gc + cost
                if ng < g.get(ns, 1e18):
                    g[ns] = ng
                    came[ns] = s
                    heapq.heappush(openh, (ng + h(jj, ii), ng, ns))
            if via_ok[j, i]:
                ns = (1 - li, j, i)
                if not block[1 - li][j, i]:
                    ng = gc + VIA_COST
                    if ng < g.get(ns, 1e18):
                        g[ns] = ng
                        came[ns] = s
                        heapq.heappush(openh, (ng + h(j, i), ng, ns))
        return None

    # ---- committing -----------------------------------------------------------
    def commit(self, net, path, w):
        ni = self.b.FindNet(net)
        segs = []
        start = path[0]
        prev = path[0]
        direction = None
        for s in path[1:]:
            if s[0] != prev[0]:
                if prev != start:
                    segs.append((start, prev))
                v = pcbnew.PCB_VIA(self.b)
                x, y = cell_xy(prev[2], prev[1])
                v.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(x), pcbnew.FromMM(y)))
                v.SetWidth(pcbnew.FromMM(VIA_D))
                v.SetDrill(pcbnew.FromMM(VIA_DRILL))
                v.SetNet(ni)
                self.b.Add(v)
                self.add_item(v)
                start, prev, direction = s, s, None
                continue
            d = (s[1] - prev[1], s[2] - prev[2])
            if direction is not None and d != direction:
                segs.append((start, prev))
                start = prev
            direction = d
            prev = s
        if prev != start:
            segs.append((start, prev))
        for a, b in segs:
            t = pcbnew.PCB_TRACK(self.b)
            xa, ya = cell_xy(a[2], a[1])
            xb, yb = cell_xy(b[2], b[1])
            t.SetStart(pcbnew.VECTOR2I(pcbnew.FromMM(xa), pcbnew.FromMM(ya)))
            t.SetEnd(pcbnew.VECTOR2I(pcbnew.FromMM(xb), pcbnew.FromMM(yb)))
            t.SetWidth(pcbnew.FromMM(w))
            t.SetLayer(LAYERS[a[0]])
            t.SetNet(ni)
            self.b.Add(t)
            self.add_item(t)

    def net_pads(self, net):
        pads = []
        for fp in sorted(self.b.GetFootprints(), key=lambda f: f.GetReference()):
            for pad in sorted(fp.Pads(), key=lambda p: (p.GetNumber(), p.GetPosition().x, p.GetPosition().y)):
                if pad.GetNetname() == net:
                    pads.append(pad)
        return pads

    def pad_cells(self, pad):
        m = np.zeros((2, NY, NX), bool)
        for li, layer in enumerate(LAYERS):
            if pad.IsOnLayer(layer):
                for pts in poly_points(pad.GetEffectivePolygon(layer, pcbnew.ERROR_INSIDE)):
                    fill_poly(m[li], pts)
        return m

    def route_net(self, net):
        widths = [WIDTH.get(net, DEFAULT_W)]
        if widths[0] > 0.3:
            widths += [0.3]          # neck-down where a wide track does not fit
        pads = self.net_pads(net)
        if len(pads) < 2:
            return True
        w = widths[0]
        block, via_ok = self.masks(net, w)
        fallback = [self.masks(net, x) for x in widths[1:]]
        # group pads into one tree, connecting the nearest pad each time
        tree = self.pad_cells(pads[0])
        for li in (0, 1):
            tree[li] |= self.routed[li].get(net, np.zeros((NY, NX), bool))
        todo = pads[1:]
        ok = True
        while todo:
            tc = np.argwhere(tree)
            cy, cx = tc[:, 1].mean(), tc[:, 2].mean()

            def dist(p):
                q = p.GetPosition()
                return (to_mm(q.x) - (X0 + cx * G)) ** 2 + (to_mm(q.y) - (Y0 + cy * G)) ** 2
            todo.sort(key=dist)
            pad = todo.pop(0)
            tgt = self.pad_cells(pad)
            if (tgt & tree).any():
                tree |= tgt
                continue
            for li in (0, 1):
                tgt[li] &= ~block[li] | self.pad_cells(pad)[li]
            src = tree.copy()
            # pads themselves are always enterable for their own net
            b2 = [block[0] & ~(src[0] | tgt[0]), block[1] & ~(src[1] | tgt[1])]
            path = self.astar(src, tgt, b2, via_ok)
            wp = w
            for wf, (bf, vf) in zip(widths[1:], fallback):
                if path is not None:
                    break
                print("  .. retry", net, "at", wf, "mm")
                b2f = [bf[0] & ~(src[0] | tgt[0]), bf[1] & ~(src[1] | tgt[1])]
                path = self.astar(src, tgt, b2f, vf)
                wp = wf
            if path is None:
                print("  !! no route for", net, "to", pad.GetParentFootprint().GetReference(), pad.GetNumber())
                ok = False
                continue
            self.commit(net, path, wp)
            if fallback:
                block, via_ok = self.masks(net, w)
                fallback = [self.masks(net, x) for x in widths[1:]]
            for li, j, i in path:
                tree[li, j, i] = True
            tree |= tgt
        return ok

    # ---- ground fan-out -----------------------------------------------------
    def gnd_fanout(self, skip_refs=(), only_refs=None):
        net = GND
        ni = self.b.FindNet(net)
        block, via_ok = self.masks(net, GND_W)
        rv = CLR + VIA_D / 2 + MARGIN
        for fp in sorted(self.b.GetFootprints(), key=lambda f: f.GetReference()):
            if fp.GetReference() in skip_refs or (only_refs and fp.GetReference() not in only_refs):
                continue
            for pad in sorted(fp.Pads(), key=lambda p: (p.GetNumber(), p.GetPosition().x, p.GetPosition().y)):
                if pad.GetNetname() != net or pad.HasHole():
                    continue
                if not pad.IsOnLayer(pcbnew.F_Cu):
                    continue
                if any(pad.HitTest(v.GetPosition()) for v in self.b.GetTracks()
                       if v.GetClass() == "PCB_VIA" and v.GetNetname() == net):
                    continue
                src = self.pad_cells(pad)
                src[1][:] = False
                tgt = np.zeros((2, NY, NX), bool)
                tgt[0] = via_ok & ~block[0]
                # only a short stub: limit the search window
                p = pad.GetPosition()
                cx, cy = to_mm(p.x), to_mm(p.y)
                path = None
                for reach in (2.0, 5.0):
                    win = (np.abs(XS[None, :] - cx) < reach) & (np.abs(YS[:, None] - cy) < reach)
                    t2 = tgt.copy()
                    t2[0] &= win
                    b2 = [block[0] & ~src[0], np.ones((NY, NX), bool)]
                    path = self.astar(src, t2, b2, np.zeros((NY, NX), bool), 400000)
                    if path is not None:
                        break
                if path is None:
                    j, i = int(round((cy - Y0) / G)), int(round((cx - X0) / G))
                    if dilate(self.other(1, net), rv)[j, i] or dilate(self.holes, 0.4)[j, i]:
                        print("  -- no GND via at", fp.GetReference(), pad.GetNumber(), "(F.Cu pour only)")
                        continue
                    print("  -- GND via in pad", fp.GetReference(), pad.GetNumber())
                    path = [(0, j, i)]
                end = path[-1]
                if len(path) > 1:
                    self.commit(net, path, GND_W)
                v = pcbnew.PCB_VIA(self.b)
                x, y = cell_xy(end[2], end[1])
                v.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(x), pcbnew.FromMM(y)))
                v.SetWidth(pcbnew.FromMM(VIA_D))
                v.SetDrill(pcbnew.FromMM(VIA_DRILL))
                v.SetNet(ni)
                self.b.Add(v)
                self.add_item(v)
                block, via_ok = self.masks(net, GND_W)


def via_in_pad(board, ref, pads):
    fp = board.FindFootprintByReference(ref)
    gnd = board.FindNet(GND)
    for n in pads:
        p = fp.FindPadByNumber(n).GetPosition()
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(p)
        v.SetWidth(pcbnew.FromMM(VIA_D))
        v.SetDrill(pcbnew.FromMM(VIA_DRILL))
        v.SetNet(gnd)
        board.Add(v)


def main():
    board = pcbnew.LoadBoard(PCB)
    # remove earlier router output, keep locked (hand-drawn) tracks
    for t in list(board.GetTracks()):
        if not t.IsLocked():
            board.Remove(t)
    # SIM7080G centre pads: one via each into the GND planes
    via_in_pad(board, "U1", ["70", "71", "72", "73", "74", "75", "76", "77", "45", "63", "66", "67"])
    r = Router(board)
    print("GND fan-out of the modem first (its pads are the tightest)")
    r.gnd_fanout(only_refs=("U1",))
    failed = []
    names = set(board.GetNetsByName().keys()) if hasattr(board, "GetNetsByName") else set()
    for net in ORDER:
        if board.FindNet(net) is None and board.FindNet(net.lstrip("/")) is not None:
            net = net.lstrip("/")
        print("routing", net)
        if not r.route_net(net):
            failed.append(net)
    print("GND fan-out")
    r.gnd_fanout(skip_refs=("J3",))   # U.FL ground pads: reached by the F.Cu pour
    pcbnew.SaveBoard(PCB, board)
    print("failed:", failed)


def stitch_islands():
    """Give every F.Cu/B.Cu ground-pour fragment without a via its own via."""
    board = pcbnew.LoadBoard(PCB)
    filler = pcbnew.ZONE_FILLER(board)
    filler.Fill(board.Zones())
    r = Router(board)
    gnd = board.FindNet(GND)
    _, via_ok = r.masks(GND, GND_W)
    anchors = [t.GetPosition() for t in board.GetTracks()
               if t.GetClass() == "PCB_VIA" and t.GetNetname() == GND]
    anchors += [p.GetPosition() for fp in board.GetFootprints() for p in fp.Pads()
                if p.GetNetname() == GND and p.HasHole()]
    added = 0
    for z in board.Zones():
        if z.GetIsRuleArea() or z.GetNetname() != GND or z.GetLayer() not in LAYERS:
            continue
        polys = z.GetFilledPolysList(z.GetLayer())
        for o in range(polys.OutlineCount()):
            one = pcbnew.SHAPE_POLY_SET()
            one.AddOutline(polys.Outline(o))
            if any(one.Contains(a) for a in anchors):
                continue
            m = np.zeros((NY, NX), bool)
            fill_poly(m, poly_points(one)[0])
            cand = np.argwhere(m & via_ok)
            if len(cand) == 0:
                print("  island without room for a via at", poly_points(one)[0][0])
                continue
            j, i = (int(v) for v in cand[len(cand) // 2])
            v = pcbnew.PCB_VIA(board)
            x, y = cell_xy(i, j)
            v.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(x), pcbnew.FromMM(y)))
            v.SetWidth(pcbnew.FromMM(VIA_D))
            v.SetDrill(pcbnew.FromMM(VIA_DRILL))
            v.SetNet(gnd)
            board.Add(v)
            r.add_item(v)
            anchors.append(v.GetPosition())
            _, via_ok = r.masks(GND, GND_W)
            added += 1
    filler.Fill(board.Zones())
    pcbnew.SaveBoard(PCB, board)
    print("island vias added:", added)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "islands":
        stitch_islands()
    else:
        main()
