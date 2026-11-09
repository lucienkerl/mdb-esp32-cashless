#!/usr/bin/env python3
"""Turn KiCad's BOM / position CSVs into JLCPCB's assembly format.

Usage: jlc.py bom.csv pos.csv outdir
Test points, mounting holes and the bottom pin header (hand-soldered) are
left out of the CPL; BOM rows without a footprint (power flags) are dropped.
"""
import csv
import os
import sys

bom_in, pos_in, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
SKIP = ("TP", "H", "J1")


def expand(refs):
    """'Q1-Q4' -> Q1,Q2,Q3,Q4 (KiCad collapses consecutive references)."""
    out = []
    for r in refs.split(","):
        r = r.strip()
        if "-" in r:
            a, b = r.split("-")
            pre = a.rstrip("0123456789")
            out += ["%s%d" % (pre, n) for n in range(int(a[len(pre):]), int(b[len(pre):]) + 1)]
        elif r:
            out.append(r)
    return out

with open(bom_in) as f, open(os.path.join(out, "BOM_JLCPCB.csv"), "w", newline="") as g:
    w = csv.writer(g)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #", "MPN / note", "Quantity"])
    for row in csv.DictReader(f):
        if not row["Footprint"]:
            continue
        refs = expand(row["Reference"])
        if all(r.startswith(SKIP) for r in refs):
            continue
        w.writerow([row["Value"], ",".join(refs), row["Footprint"].split(":")[-1],
                    row.get("LCSC", ""), row.get("MPN", ""), len(refs)])

with open(pos_in) as f, open(os.path.join(out, "CPL_JLCPCB.csv"), "w", newline="") as g:
    w = csv.writer(g)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for row in csv.DictReader(f):
        ref = row["Ref"]
        if ref.startswith(SKIP):
            continue
        w.writerow([ref, row["PosX"] + "mm", row["PosY"] + "mm",
                    "Top" if row["Side"] == "top" else "Bottom", row["Rot"]])
print("wrote", out + "/BOM_JLCPCB.csv", out + "/CPL_JLCPCB.csv")
