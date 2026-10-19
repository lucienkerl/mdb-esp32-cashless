# WROOM-1U MDB slave enclosure: clips + screws

PETG enclosure for the `mdb_slave_esp32s3-wroom-1u` board. The lid snaps on with
4 clips. Four optional M2.5 screws in external bosses hold it more firmly.
For a lid held by clips only, see [`../clips`](../clips).

![Exploded view](preview_exploded.png)

## Board mounting

Photo taken on the printed [clips](../clips) variant. The board sits on the same
four standoffs with M2.5 heat inserts in this variant.

![Board screwed in the base](../clips/screwed_assembly.png)

## Files

| File | Content |
|------|---------|
| `base.stl` / `base.step` | Base with board standoffs and mounting ears |
| `lid.stl` / `lid.step` | Lid. The STL is flipped: outer face on the bed, clips up |
| `build_case.py` | Parametric FreeCAD source for both parts |
| `case_wroom-u1_screw-clips.3mf` | Slicer project (base + lid) |

## Dimensions

- Base: 195 × 54.7 × 26 mm (mounting ears and screw bosses included).
- Closed height: 28 mm.
- Board bottom sits 7 mm above the bottom of the base.

## Openings

- **USB-C:** 12.8 × 7.2 mm window in the west wall, flush with the connector.
- **MDB (Mini-Fit 2×3):** 15.6 × 12.5 mm window in the south wall.
- **Terminal blocks:** one 4.0 × 8.4 mm wire window per pole (30 poles on the south,
  north and east walls), plus a Ø4 hole in the lid above each terminal screw. The poles
  sit 5.08 mm apart, so 4.0 mm leaves 1.08 mm webs between neighbouring openings: two
  lines with a 0.4 mm nozzle (`TERM_W` in the script).
- **LED D0 (WS2812B):** Ø4 hole in the lid.
- **Antenna:** 3 × 2 mm slot at the top of the north wall, under the lid, close to the
  ESP32 U.FL connector.
- **UART debug:** 8 × 2 mm slot at the top of the north wall, under the lid, above
  the J1 header (EN/TXD/RXD/IO0). Lets debug wires out with the lid closed.
- **Ventilation:** 1.6 × 3.4 mm slots below the board in the long walls, and
  1.6 × 12 mm slots in the lid above the relays and the centre area. Air flows in at
  the bottom and out at the top.

## Closing

- **Clips:** 4 tabs (8 × 1.2 mm, 0.6 mm catch) snap into windows in the north and
  south walls. To open, push each catch inwards through its window with a small
  screwdriver.
- **Screws (optional):** 4 external bosses with M2.5 × 5 × Ø3.5 heat inserts. Use
  M2.5 × 8 pan-head screws.

## Mounting

Two 4 mm thick ears. Each has a 10 × 4.5 mm slot for an M4 screw and two 9 × 3.2 mm
zip-tie slots. The ears are solid underneath and sit flat on the print bed, so the
screw clamps solid plastic.

## Hardware

- 8 heat inserts M2.5 × 5 × Ø3.5: 4 for the board, 4 for the lid bosses.
- Insert bore: Ø3.3 × 5.6 mm with a lead-in chamfer. Validated on a test coupon:
  3.3 mm fits, 3.4 mm is too loose. Change `INSERT_BORE` if your inserts differ.
- 4 M2.5 × 6 screws for the board. Optional: 4 M2.5 × 8 screws for the lid.

## Printing

Starting point:
- PETG, 0.4 mm nozzle, 0.2 mm layers, 3 perimeters, 20 % infill, no supports.
- No web between two openings is thinner than 1 mm, so nothing drops out at 0.4 mm.
- Base flat on its bottom face. Lid as exported: outer face on the bed.
- The wall windows need short bridges (15.6 mm maximum).
  Check them in the slicer preview.

## Regenerating

Edit the parameters at the top of `build_case.py`, then run from this folder:

```bash
"C:\Program Files\FreeCAD 1.1\bin\freecadcmd.exe" build_case.py
```

The script reads the board model from [`../pcb_wroom-u1.step`](../pcb_wroom-u1.step)
(STEP export of `kicad/mdb_slave_esp32s3-wroom-1u`). It rewrites the STEP and STL files
and prints geometry checks: solid validity, base/lid overlap and collisions with the
board.

## Limitations

- The collision check covers the geometry in the board STEP only. Mating plugs,
  cables and tools are not modelled.
- The WS2812B LED has no 3D model in the STEP. Its position comes from the
  `.kicad_pcb` file.
- The RST and BOOT buttons are only reachable with the lid off.
- Clip retention is a first estimate. Tune `BUMP` and `CLIP_T` after a test print.
