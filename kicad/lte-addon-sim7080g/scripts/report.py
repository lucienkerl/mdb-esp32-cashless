#!/usr/bin/env python3
"""Summarise build/erc.json and build/drc.json."""
import collections
import json
import os

B = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build")
for name in ("erc", "drc"):
    d = json.load(open(os.path.join(B, name + ".json")))
    vs = d.get("violations", []) if name == "drc" else [v for s in d["sheets"] for v in s["violations"]]
    c = collections.Counter((v["severity"], v["type"]) for v in vs if not v.get("excluded"))
    print(name.upper(), dict(c))
    for v in vs:
        if v["severity"] == "error" and not v.get("excluded"):
            print("  ", v["type"], "|", " || ".join(i["description"] for i in v["items"]))
    if name == "drc":
        print("  unconnected:", len(d.get("unconnected_items", [])),
              " schematic parity:", len(d.get("schematic_parity", [])))
        for v in d.get("unconnected_items", [])[:30]:
            print("   UNC", " || ".join(i["description"] for i in v["items"]))
        for v in d.get("schematic_parity", [])[:30]:
            print("   PAR", v["description"], " || ".join(i["description"] for i in v["items"]))
