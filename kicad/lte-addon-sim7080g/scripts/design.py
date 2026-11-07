"""Single source of truth for the LTE add-on module (SIM7080G on J2).

Both generators (gen_sch.py -> .kicad_sch, gen_pcb.py -> .kicad_pcb) read
the part list and the pin->net map from here, so schematic and layout can't
drift apart. The PCB uses the *mainboard's* coordinate system
(kicad/mdb_slave_esp32s3-wroom-1u), so the header lands exactly on the
mainboard's J2 socket and the outline can be checked against the parts below.

Mainboard J2 (1x6 socket, rev 1.4.1):
  1 MTMS = GPIO42   2 MTDI = GPIO41   3 MTDO = GPIO40   4 MTCK = GPIO39
  5 GND             6 +3V3

Supply: the modem runs from the mainboard's 3V3 rail through J2, like on the
mdb-slave-esp32s3-sim7080g board (SIM7080G VBAT range 2.7-4.8 V, LTE-M/NB-IoT
only, no 2G bursts). Bulk capacitance sits on this module, next to VBAT.
"""

PROJECT = "lte-addon-sim7080g"

# GPIO roles (firmware: modem.c / mdb-slave-esp32s3.c)
#   GPIO40 ESP TX  -> modem UART1_RXD (via level shifter Q1)
#   GPIO39 ESP RX  <- modem UART1_TXD (via level shifter Q2)
#   GPIO41 PWRKEY  -> Q3 pulls PWRKEY low (GPIO high = "press", same
#                     polarity as MODEM_PWRKEY_INVERTED=1)
#   GPIO42 DETECT  <- R8 pulls it up to 3V3: HIGH when the module is plugged
#                     in, LOW (internal pull-down) when it is not

GND_PINS_U2 = ["8", "13", "19", "21", "27", "30", "31", "33", "36", "37", "45",
               "63", "66", "67", "69", "70", "71", "72", "73", "74", "75", "76", "77"]

# (ref, lib_id, value, footprint, {pin: net}, extra)
# extra: dnp (bool), side ('F'/'B'), mpn, note
PARTS = [
    # --- mainboard connector (bottom side) ----------------------------------
    ("J1", "Connector_Generic:Conn_01x06", "To mainboard J2",
     "Connector_PinHeader_2.54mm:PinHeader_1x06_P2.54mm_Vertical",
     {"1": "DETECT", "2": "PWRKEY_CTL", "3": "ESP_TX", "4": "ESP_RX",
      "5": "GND", "6": "+3V3"},
     {"side": "B", "mpn": "Male pin header 1x6 2.54 mm, mounted on the bottom"}),

    # --- modem supply ---------------------------------------------------------
    ("R1", "Device:R", "0", "Resistor_SMD:R_1206_3216Metric",
     {"1": "+3V3", "2": "VBAT"},
     {"note": "Modem supply link. Remove and bridge with an ammeter to measure the modem current."}),
    ("C1", "Device:C_Polarized", "220uF 6.3V", "Capacitor_Tantalum_SMD:CP_EIA-3528-21_Kemet-B",
     {"1": "VBAT", "2": "GND"}, {"mpn": "low-ESR tantalum, e.g. Kemet T520B227M006"}),
    ("C2", "Device:C", "100uF 6.3V", "Capacitor_SMD:C_1210_3225Metric",
     {"1": "VBAT", "2": "GND"}, {}),
    ("C3", "Device:C", "22uF 10V", "Capacitor_SMD:C_0805_2012Metric",
     {"1": "VBAT", "2": "GND"}, {}),
    ("C4", "Device:C", "100nF", "Capacitor_SMD:C_0603_1608Metric",
     {"1": "VBAT", "2": "GND"}, {}),
    ("C5", "Device:C", "33pF", "Capacitor_SMD:C_0603_1608Metric",
     {"1": "VBAT", "2": "GND"}, {}),
    ("C6", "Device:C", "10pF", "Capacitor_SMD:C_0603_1608Metric",
     {"1": "VBAT", "2": "GND"}, {}),

    # --- modem ---------------------------------------------------------------
    ("U1", "vmflow_lte:SIM7080G", "SIM7080G", "vmflow_lte:XCVR_SIM7080G",
     {"34": "VBAT", "35": "VBAT",
      **{p: "GND" for p in GND_PINS_U2},
      "39": "PWRKEY", "40": "VDD_EXT", "41": "NETLIGHT", "42": "STATUS",
      "1": "MDM_TXD", "2": "MDM_RXD",
      "32": "RF_ANT",
      "18": "SIM_VDD", "17": "SIM_RST", "16": "SIM_CLK", "15": "SIM_DATA"},
     {"mpn": "SIMCom SIM7080G"}),

    # --- level shifters 3.3 V <-> 1.8 V (as on the SIM7080G board) -----------
    ("Q1", "Transistor_BJT:Q_NPN_BEC", "MMBT3904", "Package_TO_SOT_SMD:SOT-23",
     {"1": "Q1_B", "2": "ESP_TX", "3": "MDM_RXD"}, {}),
    ("R2", "Device:R", "4.7k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "VDD_EXT", "2": "Q1_B"}, {}),
    ("R3", "Device:R", "10k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "VDD_EXT", "2": "MDM_RXD"}, {}),
    ("Q2", "Transistor_BJT:Q_NPN_BEC", "MMBT3904", "Package_TO_SOT_SMD:SOT-23",
     {"1": "Q2_B", "2": "MDM_TXD", "3": "ESP_RX"}, {}),
    ("R4", "Device:R", "4.7k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "VDD_EXT", "2": "Q2_B"}, {}),
    ("R5", "Device:R", "10k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "+3V3", "2": "ESP_RX"}, {}),

    # --- PWRKEY ---------------------------------------------------------------
    ("Q3", "Transistor_BJT:Q_NPN_BEC", "MMBT3904", "Package_TO_SOT_SMD:SOT-23",
     {"1": "Q3_B", "2": "GND", "3": "PWRKEY"}, {}),
    ("R6", "Device:R", "4.7k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "PWRKEY_CTL", "2": "Q3_B"}, {}),
    ("R7", "Device:R", "4.7k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "Q3_B", "2": "GND"},
     {"note": "Keeps Q3 off against a weak pull-up on GPIO41 during ESP reset."}),

    # --- module detect --------------------------------------------------------
    ("R8", "Device:R", "10k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "+3V3", "2": "DETECT"}, {}),

    # --- network LED ----------------------------------------------------------
    ("Q4", "Transistor_BJT:Q_NPN_BEC", "MMBT3904", "Package_TO_SOT_SMD:SOT-23",
     {"1": "Q4_B", "2": "GND", "3": "LED_K"}, {}),
    ("R9", "Device:R", "4.7k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "NETLIGHT", "2": "Q4_B"}, {}),
    ("R10", "Device:R", "47k", "Resistor_SMD:R_0603_1608Metric",
     {"1": "Q4_B", "2": "GND"}, {}),
    ("R11", "Device:R", "330", "Resistor_SMD:R_0603_1608Metric",
     {"1": "VBAT", "2": "LED_A"}, {}),
    ("D1", "Device:LED", "green", "LED_SMD:LED_0603_1608Metric",
     {"1": "LED_K", "2": "LED_A"}, {}),

    # --- SIM card -------------------------------------------------------------
    ("J2", "Connector:JAE_SIM_Card_SF72S006", "Nano-SIM",
     "Connector_JAE:JAE_SIM_Card_SF72S006",
     {"C1": "SIM_VDD", "C2": "SIM_RST_C", "C3": "SIM_CLK_C", "C5": "GND",
      "C7": "SIM_DATA_C", "SH": "GND"}, {"mpn": "JAE SF72S006VBDR2000"}),
    ("R12", "Device:R", "22", "Resistor_SMD:R_0603_1608Metric",
     {"1": "SIM_RST", "2": "SIM_RST_C"}, {}),
    ("R13", "Device:R", "22", "Resistor_SMD:R_0603_1608Metric",
     {"1": "SIM_CLK", "2": "SIM_CLK_C"}, {}),
    ("R14", "Device:R", "22", "Resistor_SMD:R_0603_1608Metric",
     {"1": "SIM_DATA", "2": "SIM_DATA_C"}, {}),
    ("C7", "Device:C", "100nF", "Capacitor_SMD:C_0603_1608Metric",
     {"1": "SIM_VDD", "2": "GND"}, {}),

    # --- LTE antenna: pi match (0R + 2x NC) to U.FL -------------------------
    ("R15", "Device:R", "0", "Resistor_SMD:R_0603_1608Metric",
     {"1": "RF_ANT", "2": "RF_UFL"}, {"note": "pi match series element"}),
    ("C8", "Device:C", "NC", "Capacitor_SMD:C_0603_1608Metric",
     {"1": "RF_ANT", "2": "GND"}, {"dnp": True}),
    ("C9", "Device:C", "NC", "Capacitor_SMD:C_0603_1608Metric",
     {"1": "RF_UFL", "2": "GND"}, {"dnp": True}),
    ("J3", "Connector:Conn_Coaxial", "LTE U.FL",
     "Connector_Coaxial:U.FL_Hirose_U.FL-R-SMT-1_Vertical",
     {"1": "RF_UFL", "2": "GND"}, {"mpn": "Hirose U.FL-R-SMT-1"}),

    # --- test points ----------------------------------------------------------
    ("TP1", "Connector:TestPoint", "STATUS", "TestPoint:TestPoint_Pad_D1.0mm",
     {"1": "STATUS"}, {}),
    ("TP2", "Connector:TestPoint", "VBAT", "TestPoint:TestPoint_Pad_D1.0mm",
     {"1": "VBAT"}, {}),
    ("TP3", "Connector:TestPoint", "GND", "TestPoint:TestPoint_Pad_D1.0mm",
     {"1": "GND"}, {}),

    # --- mechanics ------------------------------------------------------------
    ("H1", "Mechanical:MountingHole", "M2 spacer", "MountingHole:MountingHole_2.2mm_M2",
     {}, {"note": "optional 11 mm nylon spacer resting on the mainboard"}),
    ("H2", "Mechanical:MountingHole", "M2 spacer", "MountingHole:MountingHole_2.2mm_M2",
     {}, {"note": "optional 11 mm nylon spacer resting on the mainboard"}),

    # --- power flags (schematic only) -----------------------------------------
    ("#FLG01", "power:PWR_FLAG", "PWR_FLAG", "", {"1": "GND"}, {}),
    ("#FLG02", "power:PWR_FLAG", "PWR_FLAG", "", {"1": "+3V3"}, {}),
    ("#FLG03", "power:PWR_FLAG", "PWR_FLAG", "", {"1": "VBAT"}, {}),
]

SCH_GROUPS = [
    ("Mainboard connector (J2 socket on the WROOM-1U board)", ["J1", "R8", "#FLG01", "#FLG02"]),
    ("Modem supply (from the mainboard 3V3)", ["R1", "C1", "C2", "C3", "C4", "C5", "C6", "#FLG03"]),
    ("SIM7080G", ["U1"]),
    ("UART level shifters 3.3 V <-> 1.8 V", ["Q1", "R2", "R3", "Q2", "R4", "R5"]),
    ("PWRKEY (GPIO41 high = key pressed)", ["Q3", "R6", "R7"]),
    ("Network LED", ["Q4", "R9", "R10", "R11", "D1"]),
    ("Nano-SIM", ["J2", "R12", "R13", "R14", "C7"]),
    ("LTE antenna", ["R15", "C8", "C9", "J3"]),
    ("Test points and mechanics", ["TP1", "TP2", "TP3", "H1", "H2"]),
]
