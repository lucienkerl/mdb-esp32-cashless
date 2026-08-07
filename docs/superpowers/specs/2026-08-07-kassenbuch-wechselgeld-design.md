# Kassenbuch: Wechselgeld in Automaten (`change_float`)

**Datum:** 2026-08-07
**Status:** Design approved (user), pending spec review

## Problem

Das Kassenbuch (`cash_book_entries`) kennt sechs Buchungsarten: `initial`,
`withdrawal` (Geld aus dem Automaten in die Kasse, positiv), `payout`
(Bankeinzahlung, negativ), `expense` (Barausgabe, negativ, mit Kategorie +
Beleg), `correction` (signiert) und `reversal` (Storno).

Für einen alltäglichen Vorgang gibt es keine passende Art: der Betreiber nimmt
Bargeld aus der Barkasse (oder aus dem eben kassierten Geld) und füllt damit die
**Münztuben** des Münzwechslers auf, damit der Automat Wechselgeld ausgeben
kann.

Heute bleiben nur schlechte Behelfe:

- **Gar nicht buchen** → der Buchbestand ist dauerhaft zu hoch. Nach GoBD ein
  Kassenfehlbetrag. Die Hash-Kette validiert nur die Buchungskette gegen sich
  selbst, nicht gegen den Ist-Bestand, merkt also nichts.
- **Als `expense` buchen** → falsch: die DB erzwingt Kategorie + Belegverweis,
  und das Geld erscheint in KPI-Kachel und PDF-Export als Betriebsausgabe. Es
  verlässt das Unternehmen aber gar nicht.
- **Als `correction` buchen** → funktioniert rechnerisch (der Hinweistext lautet
  „Positiv = Zugang, negativ = Abgang"), vermischt aber Wechselgeld dauerhaft
  mit echten Zähldifferenzen in `totalCorrections`, im Typfilter und im PDF.

Zusätzlich verschwindet das Geld in allen drei Varianten aus der
Gesamtübersicht. Der Flow „In Automaten → In der Kasse → Bank" zeigt es nirgends,
obwohl es Firmengeld ist.

## Ziel

Eine eigene Buchungsart, die

1. den Kassenstand korrekt senkt bzw. hebt,
2. nicht als Betriebsausgabe zählt,
3. je Automat einen exakten Bestand „so viel Wechselgeld habe ich diesem
   Automaten vorgestreckt" führt,

auf PWA und nativer iOS-App, rückwärtskompatibel zu Altdaten und zu im Feld
laufenden App-Versionen.

## Fachliche Grundlage: was messbar ist und was nicht

Der **Füllstand der Münztuben ist von außen nicht ermittelbar**. Kundschaft
wirft Münzen ein, der Wechsler gibt Münzen aus; der Stand schwankt
unvorhersehbar.

Die **Gesamtsumme im Automaten** ist dagegen exakt bestimmt. Beispiel: Kunde
zahlt mit 20-€-Schein für einen Artikel zu 2 €, der Automat gibt 18 €
Wechselgeld zurück. Der Automat hat netto genau die 2 € des Verkaufs gewonnen.
Tuben und Kassette verschieben sich gegeneinander, die Summe folgt exakt den
Barverkäufen.

Daraus folgt die Modellierungsentscheidung:

- **Nicht modelliert:** „in den Tuben liegen X €" — das wäre erfunden.
- **Modelliert:** „ich habe diesem Automaten X € vorgestreckt" — exakt, weil
  sich dieser Wert ausschließlich durch eigene Buchungen ändert, nie durch
  Kundschaft.

## Entscheidungen (mit dem Nutzer abgestimmt)

1. **Bestandsgröße:** vorgestrecktes Wechselgeld **je Automat**, nicht
   firmenweit aggregiert und nicht als Tubenfüllstand.
2. **Kein Soll-Bestand.** Es gibt keine Spalte „dieser Automat soll X €
   Rollgeld vorhalten". Der Bestand ist rein buchungsabgeleitet.
3. **Eine Buchungsart mit Vorzeichen** (`change_float`), nicht zwei
   richtungsfeste Typen. Begründung unter „Verworfene Alternativen".
4. **Plattformen:** PWA **und** iOS. Das Auffüllen passiert vor Ort am
   Automaten; nur-Web würde bedeuten, dass Beträge notiert und später nachgebucht
   werden — also vergessen werden.
5. **Beim Leeren wird der volle Betrag gebucht**, die Tubenrücklage separat.
   Nicht: „nur den mitgenommenen Betrag erfassen". Damit bleibt der
   Soll-Ist-Vergleich gegen die Barverkäufe aussagekräftig und die
   GoBD-Vollständigkeit gewahrt.
6. **Atomarität über eine RPC.** Die Doppelbuchung darf nicht halb passieren.

## Vorzeichenkonvention

`amount` ist durchgehend die **Wirkung auf die Barkasse** — identisch zu allen
bestehenden Buchungsarten.

| Vorgang | `amount` | Wirkung Kassenstand | Wirkung Float |
|---|---|---|---|
| Wechselgeld in den Automaten | negativ | sinkt | steigt |
| Wechselgeld aus dem Automaten zurück | positiv | steigt | sinkt |

Der Float-Bestand je Automat ist damit `−SUM(amount)`.

Die Dialoge fragen **nie ein rohes Vorzeichen ab**, sondern Richtung + Betrag
≥ 0 und rechnen intern um — genau wie `recordBankDeposit` es heute schon macht
(`CashBookViewModel.swift`).

## Datenmodell

Neue Migration `20260807000000_cash_book_change_float.sql`. Bestehende
Migrationen sind immutable und werden NIE editiert. Alle Operationen idempotent.

**Keine neue Tabelle, keine neue Spalte.** Der Wechselgeldbestand ist kein
gespeicherter Wert, sondern eine Summe über die Buchungen — wie der Kassenstand
selbst. Damit kann er per Konstruktion nicht von der Buchungshistorie abweichen.

### A. Typ-Whitelist erweitern

```sql
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS valid_type;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT valid_type
  CHECK (type IN ('initial','withdrawal','correction','payout','expense',
                  'change_float','reversal'));
```

Der Code heißt `change_float`, nicht `float`: `float` ist ein SQL-Typname und
liest sich in `type = 'float'` irreführend.

### B. Nullbuchung sperren

```sql
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS change_float_nonzero;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT change_float_nonzero
  CHECK (type <> 'change_float' OR amount <> 0);
```

### C. Automatenbezug erzwingen — im Trigger, NICHT als CHECK

Das ist der nicht offensichtliche Punkt des Entwurfs.

`machine_id` hängt an `REFERENCES public."vendingMachine"(id) ON DELETE SET NULL`
(`20260407000000_cash_book.sql`, Zeile 68). Ein CHECK
`type <> 'change_float' OR machine_id IS NOT NULL` würde bei **jedem UPDATE**
neu ausgewertet. Das Löschen eines Automaten löst über `ON DELETE SET NULL`
genau so ein UPDATE aus — die Löschung würde am Constraint scheitern.

Die Regel gehört deshalb als `RAISE EXCEPTION` in
`before_insert_cash_book_entry`, ein BEFORE-**INSERT**-Trigger, der bei
`ON DELETE SET NULL` nicht feuert. Ergebnis: der Automat bleibt löschbar, die
Buchung bleibt erhalten, nur die Zuordnung fällt weg.

Die Funktion wird per `CREATE OR REPLACE` neu deklariert. **Basis ist die
aktuelle Fassung aus `20260522120000_fix_cash_book_digest_search_path.sql`**,
nicht die Urfassung — inklusive `SET search_path = public, extensions`, sonst
fällt der digest()-Fix zurück und jeder Kassenbuch-Insert bricht mit 42883.

Ergänzung am Kopf der Funktion:

```sql
IF NEW.type = 'change_float' AND NEW.machine_id IS NULL THEN
  RAISE EXCEPTION 'change_float requires machine_id';
END IF;
```

Die Bedingung prüft ausschließlich `NEW.type = 'change_float'`. Ein Storno
trägt `type = 'reversal'` und läuft daran vorbei — Stornos von
Wechselgeldbuchungen bleiben also möglich, obwohl die Gegenbuchung keine
`machine_id` trägt. Der Bestand wird trotzdem korrekt zurückgenommen, weil die
Bestandsabfrage über `is_reversed` filtert (siehe unten).

### D. Partieller Index

```sql
CREATE INDEX IF NOT EXISTS idx_cash_book_entries_change_float
  ON public.cash_book_entries (company_id, machine_id)
  WHERE type = 'change_float' AND is_reversed = false;
```

### E. Alt-Daten

Alle drei Regeln sind No-ops auf Bestandsdaten: keine existierende Zeile hat
`type = 'change_float'`.

## RPC: Bestandsabfrage

`get_machine_change_float(p_company_id uuid) RETURNS jsonb`

Gleiches Muster wie `get_theoretical_cash`: `SECURITY DEFINER`,
`SET search_path = public, extensions`, Mitgliedschaftsprüfung über
`organization_members` gegen `auth.uid()`, `NULL` wenn der Aufrufer nicht zur
Firma gehört.

```sql
SELECT e.machine_id, vm.name, e.cash_book_id,
       -SUM(e.amount)     AS float_balance,
       MAX(e.created_at)  AS last_change_at
  FROM public.cash_book_entries e
  JOIN public."vendingMachine" vm ON vm.id = e.machine_id
 WHERE e.company_id  = p_company_id
   AND e.type        = 'change_float'
   AND e.is_reversed = false
 GROUP BY e.machine_id, vm.name, e.cash_book_id
HAVING ROUND((-SUM(e.amount))::numeric, 2) <> 0
```

Rückgabe: Array aus `{machine_id, machine_name, cash_book_id, float_balance,
last_change_at}`.

Zwei Fallstricke:

- **`is_reversed = false` ist zwingend.** Die Storno-Gegenbuchung trägt
  `type = 'reversal'` und hat keine `machine_id` — ohne diesen Filter würde ein
  Storno den Float-Bestand nicht zurücknehmen. Der `before_insert`-Trigger
  markiert den Originaleintrag korrekt.
- **Runden nur mit `::numeric`-Cast.** `amount` ist `float8`, und
  `ROUND(double precision, integer)` existiert in Postgres nicht. Derselbe
  Fehler hat 2026-04-11 den Steuer-Trigger und damit die MQTT-Verkaufspipeline
  für ~24 h zerlegt.

Gruppierung nach `(machine_id, cash_book_id)`: wechselt ein Automat die
Barkasse, entstehen zwei Zeilen. Das ist korrekt — der Float gehört buchhalterisch
zu einer bestimmten Barkasse. Die Oberfläche summiert für eine
automatenbezogene Anzeige.

## RPC: Entnahme mit Rücklage

`record_cash_book_withdrawal(p_cash_book_id, p_machine_id, p_counted,
p_expected, p_float_back, p_description)`

`SECURITY INVOKER`, damit die bestehenden RLS-Policies unverändert greifen.
`company_id` und `created_by` leitet die Funktion aus `my_company_id()` und
`auth.uid()` ab.

Schreibt in **einer Transaktion**, in dieser Reihenfolge:

```
1. withdrawal    amount = +p_counted
                 counted_amount = p_counted
                 expected_amount = p_expected
                 machine_id = p_machine_id   (darf NULL sein)

2. change_float  amount = −p_float_back      (nur wenn p_float_back <> 0)
                 machine_id = p_machine_id   (muss gesetzt sein)
```

Netto-Kassenwirkung: `p_counted − p_float_back`.

Vorabprüfung in der Funktion, bevor irgendetwas geschrieben wird:
`p_float_back <> 0 AND p_machine_id IS NULL` → `RAISE EXCEPTION` mit
verständlicher Meldung. Ohne diese Prüfung liefe der Fall in den generischen
Trigger-Fehler, nachdem die Entnahme bereits geschrieben wurde — die Transaktion
rollt zwar korrekt zurück, aber die Fehlermeldung wäre für die Oberfläche
unbrauchbar.

Rückgabe: beide Entry-IDs, damit der Client das Aktivitätsprotokoll schreiben
kann.

**Beide Clients rufen künftig diese RPC — auch bei Entnahmen ohne Rücklage.**
Das ist bewusst mehr Umbau als nötig und bringt zwei Dinge: es gibt nur einen
Schreibpfad statt zweier parallel gepflegter Insert-Blöcke in `useCashBook.ts`
und `CashBookViewModel.swift`, und der Pfad wird erstmals im SQL-Harness
testbar.

Verworfen: zwei sequentielle Inserts vom Client. Ein Verbindungsabbruch
dazwischen erzeugt exakt den Zustand, den die Buchungsart verhindern soll — eine
gebuchte Entnahme ohne Rücklage sieht plausibel aus und überhöht den
Kassenstand still.

Ebenfalls verworfen: Multi-Row-Insert über PostgREST. Funktioniert vermutlich,
hängt aber an einem Implementierungsdetail der Zeilenreihenfolge, das bei einem
GoBD-Kassenbuch nichts verloren hat.

## Datenfluss: die drei Praxisfälle

**Fall 1 — Rollgeld vorher aus der Kasse mitgenommen.** Eine einzelne
`change_float`-Buchung, negativ. Automat ist Pflichtfeld, Auswahl beschränkt auf
die Automaten der gewählten Barkasse. Bei genau einem zugeordneten Automaten
wird vorausgewählt.

Eigenständige Wechselgeldbuchungen laufen über den bestehenden Insert-Pfad
(`createEntry` bzw. das iOS-Pendant), nicht über die RPC. Eine einzelne Zeile
ist für sich atomar; die RPC existiert ausschließlich wegen der Verkettung in
Fall 2.

**Fall 2 — beim Leeren, aus dem kassierten Geld.** Zwei Zahlen rein („gezählt
gesamt", „davon zurück in die Tuben"), zwei verkettete Buchungen raus über die
RPC. Der Soll-Ist-Vergleich stellt weiterhin `gezählt` den Barverkäufen
gegenüber — also die volle Kassettenleerung gegen die volle Verkaufssumme. Die
Rücklage steht daneben und verfälscht ihn nicht.

**Fall 3 — Grundausstattung beim Aufstellen.** Identisch zu Fall 1. Setzt
voraus, dass der Automat der Barkasse bereits zugeordnet ist.

**Rücknahme** (Abbau, oder bewusste Senkung des Floats): `change_float` mit
positivem Betrag, gleicher Dialog mit umgeschalteter Richtung.

## Was ausdrücklich unangetastet bleibt

`get_theoretical_cash` wird **nicht geändert**. Die Anker-Logik betrachtet nur
`initial` und nicht-stornierte `withdrawal`
(`20260606000000_cash_book_per_machine_theoretical.sql`, Zeilen 117-122);
`change_float` taucht dort per Definition nicht auf, verschiebt also weder
Anker noch Erwartungswert. Bestehende Zahlen verschieben sich um exakt null.
Ein Regressionstest sichert das ab.

## Was nicht validiert wird

- **Rücklage > gezählter Betrag** ist erlaubt. 100 € kassiert, 150 € eingetubt —
  die Differenz kommt aus der Barkasse. Legitim.
- **Negativer Float-Bestand** wird nicht blockiert, nur im Dialog gewarnt. Er
  ist ein Bedienfehler (dann war es eine Entnahme, keine Rücknahme), aber
  Buchungen zu verweigern, die die Realität abbilden, wäre bei einem
  GoBD-Kassenbuch das falsche Verhalten. Korrigiert wird per Storno.

## Oberflächen

### PWA

| Datei | Änderung |
|---|---|
| `app/components/cash-book/ChangeFloatModal.vue` | **neu** — Richtung, Automat, Betrag ≥ 0, Beschreibung |
| `app/components/cash-book/WithdrawalModal.vue` | Feld „davon zurück in die Tuben"; blendet bei Betrag > 0 einen Automaten-Picker ein |
| `app/components/cash-book/StationInChangeFloat.vue` | **neu** — dritte Station „Wechselgeld vorgestreckt" |
| `app/components/cash-book/FlowVisualisation.vue` | Station einhängen (Desktop-Kette + Mobile-Stack, Zeilen 35-68) |
| `app/components/cash-book/EntriesTable.vue` | Badge-Farbe + Label, Richtung aus dem Vorzeichen |
| `app/components/cash-book/SecondaryToolbar.vue` | Button „Wechselgeld" neben Korrektur |
| `app/composables/useCashBook.ts` | Typ-Union, Entnahme auf RPC umstellen, `fetchChangeFloat`, `totalChangeFloat` |
| `app/pages/cash-book/index.vue` | Handler, `typeLabel`, PDF-Summenzeile |
| `i18n/locales/{de,en,fr,nl}.json` | alle vier Sprachen |

### iOS

| Datei | Änderung |
|---|---|
| `Views/CashBook/ChangeFloatSheet.swift` | **neu** |
| `VMflow.xcodeproj/project.pbxproj` | vier Hand-Edits für die neue Datei (PBXBuildFile, PBXFileReference, group children, Sources phase) — ohne sie kompiliert die Datei nicht mit |
| `Models/CashBook.swift` | `case changeFloat = "change_float"`; `.unknown`-Fallback bleibt |
| `ViewModels/CashBookViewModel.swift` | Entnahme auf RPC, `recordChangeFloat`, `changeFloatBalances` |
| `Views/CashBook/WithdrawalSheet.swift` | Rücklage-Feld; Automaten-Picker für den Float-Teil entkoppelt von `trackPerMachine` (heute Zeile 76) |
| `Views/CashBook/EntriesListSection.swift` | `badgeStyle`-Zweig |
| `Views/CashBook/FlowVisualisationCard.swift` | dritte Station |
| `ViewModels/RefillWizardViewModel.swift` | Rücklage im Kassenschritt der Tour |
| `Resources/Localizable.xcstrings` | de-Einträge, du-Ton, chirurgisch eingefügt (nie python-reserialisieren) |

### Entkopplung von `trackPerMachine`

`trackPerMachine` steuert, wie der **Erwartungswert** verankert wird. Wo das
Wechselgeld liegt, ist eine davon unabhängige Frage. Der Float-Automat wird
deshalb **immer** abgefragt, auch bei ausgeschalteter Einstellung.

Eine Entnahme darf weiterhin `machine_id = NULL` tragen, die zugehörige
`change_float`-Buchung nicht. Das ist konsistent: eine Float-Buchung mit
`machine_id` beeinflusst keinen Anker.

## Rückwärtskompatibilität

Der kritische Punkt sind installierte iOS-Apps, die nicht sofort aktualisiert
werden.

- **Alte iOS-Builds:** der `.unknown`-Fallback in `Models/CashBook.swift`
  (Zeile 38) fängt den neuen Typ ab. Graues „Unbekannt"-Badge, Betrag und Saldo
  korrekt, kein Absturz. Genau dafür wurde er gebaut.
- **Die neue RPC ersetzt den direkten Insert nicht, sie tritt daneben.**
  Tabelle, RLS-Policies und Trigger bleiben unverändert; alte Builds buchen
  weiter per Insert korrekte Entnahmen und können lediglich keine Rücklage
  erfassen. Kein Zwang zum Sofort-Update.
- **Alte PWA-Stände:** `typeLabel` fällt auf den rohen String zurück, Badge ohne
  Farbe. Kein Absturz. (Praktisch irrelevant, da die PWA mitdeployed wird.)
- **`get_theoretical_cash`** unverändert → keine Zahlenverschiebung.
- **api-v1:** `cash-book-entries` ist als `readOnly` registriert
  (`functions/api-v1/index.ts`, Zeile 45) und nimmt den neuen Typ automatisch
  mit. Keine Änderung, kein Leck.
- **Firmware und MQTT** sind nicht berührt.

## Tests

### SQL-Harness

`Docker/supabase/tests/cash_book_change_float.test.sql`, ausgeführt über
`run-sql-tests.sh` (plain-ASSERT in zurückgerollter Transaktion, Fake-JWT):

1. `change_float` ohne `machine_id` → Exception aus dem Trigger
2. `change_float` mit `amount = 0` → CHECK schlägt an
3. Float-Bestand entspricht `−SUM(amount)`
4. Storno einer `change_float`-Buchung nimmt den Bestand vollständig zurück
5. RPC schreibt bei `float_back = 0` eine, sonst zwei Zeilen; Saldo und
   Reihenfolge stimmen
6. **Regressionstest:** `get_theoretical_cash` liefert vor und nach einer
   `change_float`-Buchung identische Werte
7. Automat löschen, während Float offen ist → geht durch, `machine_id` wird
   NULL, Buchung bleibt erhalten

### Vitest

Vorzeichenumrechnung im Modal (Richtung + Betrag ≥ 0 → signierter `amount`) und
die clientseitige Aggregation des Float-Bestands.

### iOS

Kein Testtarget vorhanden. Die Vorzeichenumrechnung wird per Wegwerf-`swift`-
Skript geprüft, der Rest über:

```
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Verworfene Alternativen

**Zwei Buchungsarten `float_out` / `float_in`.** Folgt der bestehenden
Hausordnung (`payout` und `expense` sind richtungsfeste Typen) und erlaubt einen
Vorzeichen-CHECK. Preis: jede Stelle verzweigt zweifach — Constraint, zwei
i18n-Blöcke in vier Sprachen, zwei Badge-Farben, zwei Swift-Enum-Cases, zwei
PDF-Summenzeilen. Für eine Information, die im Vorzeichen ohnehin steht.
`correction` ist der Präzedenzfall für einen signierten Typ im selben Codebestand.

**`correction` mit Pflichtkategorie `change_float`.** Keine Constraint-Änderung
nötig, alte Clients zeigten „Korrektur" statt „Unbekannt". Fällt trotzdem durch:
`totalCorrections`, Typfilter und PDF-Summenzeile würden Wechselgeld dauerhaft
mit echten Zähldifferenzen vermischen — genau die Vermengung, die abgeschafft
werden soll.

**Tubenfüllstand modellieren.** Nicht ermittelbar, siehe „Fachliche Grundlage".

**Soll-Wechselgeldbestand je Automat** (Spalte auf `vendingMachine`). Vom
Nutzer als nicht benötigt verworfen.

## Offene Punkte für die Umsetzung

- Beim Löschen eines Automaten mit offenem Float sollte die Oberfläche warnen
  („dieser Automat hält noch X € Wechselgeld"). Nicht blockierend; die Buchung
  überlebt das Löschen, verliert aber die Zuordnung.
- Anzeige des Float-Bestands auf `/machines/[id]` ist naheliegend, aber nicht
  Teil dieses Entwurfs.
