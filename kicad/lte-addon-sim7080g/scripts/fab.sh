#!/bin/bash
# Fabrication outputs for JLCPCB: gerbers + drill (zip), BOM and CPL (CSV),
# plus top/bottom 3D renders. Run after build.sh, with KiCad 9 on the PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
# fresh KiCad installs (e.g. the docker image) have no global library tables yet
CFG="${HOME}/.config/kicad/9.0"
if [ ! -f "$CFG/sym-lib-table" ] && [ -d /usr/share/kicad/template ]; then
  mkdir -p "$CFG" && cp /usr/share/kicad/template/{sym,fp}-lib-table "$CFG/"
fi
P=lte-addon-sim7080g
OUT=fab
rm -rf "$OUT/gerber" && mkdir -p "$OUT/gerber"
kicad-cli pcb export gerbers --no-protel-ext --subtract-soldermask \
  -l F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts \
  -o "$OUT/gerber/" $P.kicad_pcb >/dev/null
kicad-cli pcb export drill --format excellon --excellon-separate-th --generate-map \
  --map-format gerberx2 -o "$OUT/gerber/" $P.kicad_pcb >/dev/null
(cd "$OUT/gerber" && rm -f ../${P}_gerber_JLCPCB.zip && zip -q ../${P}_gerber_JLCPCB.zip *)
rm -rf "$OUT/gerber"
kicad-cli pcb export pos --format csv --units mm --side both --exclude-dnp \
  -o build/pos.csv $P.kicad_pcb >/dev/null
kicad-cli sch export bom --fields 'Reference,Value,Footprint,MPN,LCSC,${QUANTITY},${DNP}' \
  --group-by 'Value,Footprint,LCSC,${DNP}' --exclude-dnp \
  -o build/bom.csv $P.kicad_sch >/dev/null
python3 scripts/jlc.py build/bom.csv build/pos.csv "$OUT"
kicad-cli pcb render --side top --quality high --width 1600 --height 1000 --zoom 1.1 \
  --background transparent -o $P.png $P.kicad_pcb >/dev/null
kicad-cli pcb render --side bottom --quality high --width 1600 --height 1000 --zoom 1.1 \
  --background transparent -o ${P}_back.png $P.kicad_pcb >/dev/null
ls -la "$OUT" $P*.png
