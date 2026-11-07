#!/bin/bash
# Regenerate schematic, board, routing and reports. Needs KiCad 9 (kicad-cli +
# pcbnew python + numpy), e.g.:
#   docker run --rm -u 0 -v "$PWD":/p -w /p kicad/kicad:9.0 bash scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# fresh KiCad installs (e.g. the docker image) have no global library tables yet
CFG="${HOME}/.config/kicad/9.0"
if [ ! -f "$CFG/sym-lib-table" ] && [ -d /usr/share/kicad/template ]; then
  mkdir -p "$CFG" && cp /usr/share/kicad/template/{sym,fp}-lib-table "$CFG/"
fi
mkdir -p build
python3 scripts/gen_sch.py
kicad-cli sch export netlist --format kicadsexpr -o build/netlist.net lte-addon-sim7080g.kicad_sch >/dev/null
kicad-cli sch erc --severity-all --format json -o build/erc.json lte-addon-sim7080g.kicad_sch >/dev/null
python3 scripts/gen_pcb.py place
python3 scripts/route.py
python3 scripts/gen_pcb.py finish
python3 scripts/route.py islands
kicad-cli pcb drc --schematic-parity --severity-all --format json -o build/drc.json lte-addon-sim7080g.kicad_pcb >/dev/null
python3 scripts/report.py
