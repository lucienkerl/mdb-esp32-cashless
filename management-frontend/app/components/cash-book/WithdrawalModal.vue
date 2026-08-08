<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import type { TheoreticalCash, VendingMachineBasic } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  theoreticalCash: TheoreticalCash | null
  assignedMachines: VendingMachineBasic[]
  trackPerMachine: boolean
  submitting: boolean
  error?: string | null
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: {
    counted: number
    expected: number
    machineId: string | null
    floatBack: number
    floats: { machineId: string; amount: number }[]
    description: string
    emptiedMachineIds: string[]
  }): void
}>()

const { t } = useI18n()

const form = ref({
  counted_amount: 0,
  description: 'Geldentnahme aus Automat',
  machine_id: null as string | null,
})

/** Rohtext des Einzel-Rücklage-Felds — bewusst `text` statt `number`, damit
 *  ein unparsbarer Wert (z. B. "1.234,50", ein von `parsedAmountIfValid`
 *  nicht unterstütztes Tausendertrennzeichen-Format) erkennbar bleibt.
 *  `type="number"` liefert für so etwas einfach `''` zurück, und
 *  `Number(x) || 0` bucht das dann still als 0 — ohne Rücklage-Zeile und
 *  ohne jede Fehlermeldung. Mirror von iOS' `floatBackText`. */
const floatBackText = ref('')

/** Rücklage-Rohtexte je Automat im Mehrfach-Modus, keyed by machine id. */
const multiFloatTexts = ref<Record<string, string>>({})

const difference = computed(() => {
  if (!props.theoreticalCash) return 0
  return form.value.counted_amount - props.theoreticalCash.cash_sales_since
})

/** Mehr als ein Automat in der Theoretical-Cash-Aufschlüsselung → die
 *  Rücklage muss je Automat erfasst werden, sonst würde der gesamte Betrag
 *  fälschlich auf einen einzigen gebucht — genau die Fehlzuordnung, die die
 *  Mehrfach-RPC beheben soll (mirror von iOS' `isMultiMachine`). Betrifft
 *  ausschließlich, ob die Rücklage in einem Feld oder pro Automat erfasst
 *  wird — die Automatenauswahl für die Entnahme selbst (`form.machine_id`)
 *  ist davon unabhängig, siehe die Picker-Bedingung unten. */
const isMultiMachine = computed(() => (props.theoreticalCash?.machines?.length ?? 0) > 1)

/** Validierender Parser für Rücklage-Beträge — Mirror von iOS'
 *  `parsedAmountIfValid`. Ein leeres Feld ist gültig (keine Rücklage → 0);
 *  ein nicht-leeres, aber nicht parsbares Feld liefert `null` — das ist der
 *  Fall, den `Number(x) || 0` bisher still auf 0 buchte, obwohl der
 *  Bediener etwas eingegeben hatte, das nie in der Buchung ankam.
 *  `replaceAll` (nicht nur die erste Fundstelle) ersetzt jedes Komma, damit
 *  ein Tausendertrennzeichen-Format wie "1.234,50" korrekt als ungültig
 *  erkannt wird ("1.234.50" ist kein parsbares JS-Number-Literal) statt in
 *  ein plausibel aussehendes, aber falsches Ergebnis zu rutschen. Ein
 *  negativer Wert ist ebenfalls ungültig statt stillschweigend auf 0
 *  geklemmt zu werden — sonst würde z. B. "-5" wie "nichts eingegeben"
 *  gebucht, ohne dass der Bediener je einen Fehler sieht. */
function parsedAmountIfValid(raw: string): number | null {
  const cleaned = raw.trim().replaceAll(',', '.')
  if (cleaned === '') return 0
  const n = Number(cleaned)
  return Number.isFinite(n) && n >= 0 ? n : null
}

const floatBackIsValid = computed(() => parsedAmountIfValid(floatBackText.value) !== null)
const floatBack = computed(() => parsedAmountIfValid(floatBackText.value) ?? 0)

/** Rücklage-Beträge je Automat im Mehrfach-Modus, ein Eintrag pro Zeile aus
 *  der Theoretical-Cash-Aufschlüsselung. */
const multiFloats = computed(() =>
  (props.theoreticalCash?.machines ?? []).map(m => ({
    machineId: m.machine_id,
    amount: parsedAmountIfValid(multiFloatTexts.value[m.machine_id] ?? '') ?? 0,
  })),
)

/** Ob jede Mehrfach-Rücklage-Zeile sauber parst — dieselbe leer-ist-gültig-
 *  /Müll-ist-ungültig-Unterscheidung wie `floatBackIsValid`, pro Zeile. */
const multiFloatsAreValid = computed(() =>
  (props.theoreticalCash?.machines ?? []).every(
    m => parsedAmountIfValid(multiFloatTexts.value[m.machine_id] ?? '') !== null,
  ),
)

const totalFloatBack = computed(() =>
  isMultiMachine.value
    ? multiFloats.value.reduce((sum, f) => sum + f.amount, 0)
    : floatBack.value,
)

/** Was nach der Tubenrücklage tatsächlich in der Kasse landet. */
const netToBox = computed(() => form.value.counted_amount - totalFloatBack.value)

/** Sobald eine Rücklage erfasst wird, ist der Automatenbezug zwingend —
 *  unabhängig von `trackPerMachine`, das nur den Erwartungswert verankert.
 *  Im Mehrfach-Modus entfällt diese Pflicht: jede Zeile trägt ihren eigenen
 *  Automaten bereits in `multiFloats`, ein zusätzlicher Top-Level-Automat
 *  wäre überflüssig. */
const machineRequired = computed(() => !isMultiMachine.value && floatBack.value > 0)

/** Checkbox-Zustand je Automat für die Entnahme-Zuordnung selbst (nicht zu
 *  verwechseln mit `multiFloatTexts`, das die Rücklage betrifft). Keyed by
 *  machine id, `true` = angehakt. Bei jedem Öffnen auf "alle angehakt"
 *  zurückgesetzt (siehe `watch` unten) — das Leeren aller Automaten ist der
 *  häufigste Fall und entspricht der heutigen NULL-Bedeutung. */
const checkedMachineIds = ref<Record<string, boolean>>({})

/** Mehr als ein zugeordneter Automat UND `trackPerMachine` an → die
 *  Entnahme kann nur einen Teil der Automaten geleert haben, das lässt sich
 *  mit einem einzelnen Dropdown nicht ausdrücken. Bewusst NICHT an
 *  `isMultiMachine` gekoppelt (das reagiert unabhängig von
 *  `trackPerMachine` auf die Rücklage-Zeilen) — ohne `trackPerMachine`
 *  bleibt das bisherige Verhalten unverändert (Aufgabenstellung). */
const showMachineCheckboxes = computed(() => props.trackPerMachine && props.assignedMachines.length > 1)

/** Bisheriges Einzel-Dropdown — jetzt nur noch gezeigt, wenn die
 *  Checkbox-Variante nicht greift (genau ein Automat, oder `trackPerMachine`
 *  aus und nur wegen `machineRequired` überhaupt sichtbar). */
const showMachinePicker = computed(() =>
  !showMachineCheckboxes.value
  && (props.trackPerMachine || machineRequired.value)
  && props.assignedMachines.length > 0,
)

const checkedMachineList = computed(() =>
  props.assignedMachines.filter(m => checkedMachineIds.value[m.id]).map(m => m.id),
)

/** Echte Teilmenge (mind. einer angehakt, aber nicht alle) → nur dann ist
 *  die neue `p_emptied_machine_ids`-Liste maßgeblich. Alle angehakt oder
 *  keiner angehakt bleiben beide die heutige NULL-Darstellung ("alle
 *  Automaten"), damit sich für den häufigen Fall nichts ändert. */
const isSubsetSelection = computed(() =>
  showMachineCheckboxes.value
  && checkedMachineList.value.length > 0
  && checkedMachineList.value.length < props.assignedMachines.length,
)

const canSubmit = computed(() =>
  form.value.counted_amount > 0
  && (isMultiMachine.value
    ? multiFloatsAreValid.value
    : floatBackIsValid.value)
  && (!machineRequired.value || form.value.machine_id !== null),
)

watch(() => props.open, (now) => {
  if (now) {
    form.value = {
      counted_amount: 0,
      description: 'Geldentnahme aus Automat',
      machine_id: props.assignedMachines.length === 1 ? props.assignedMachines[0]!.id : null,
    }
    floatBackText.value = ''
    multiFloatTexts.value = {}
    // Alle Automaten angehakt starten — Leeren aller Automaten ist der
    // häufige Fall und entspricht der heutigen NULL-Bedeutung.
    checkedMachineIds.value = Object.fromEntries(props.assignedMachines.map(m => [m.id, true]))
  }
})

function onSubmit() {
  if (!canSubmit.value) return
  emit('submit', {
    counted: form.value.counted_amount,
    expected: props.theoreticalCash?.cash_sales_since ?? 0,
    // Wenn die Checkbox-Variante aktiv ist, geht der Automatenbezug der
    // Entnahme selbst NIE über `machine_id` — bei "alle" oder "keiner"
    // angehakt bleibt das die heutige NULL-Darstellung ("alle Automaten
    // dieser Barkasse geleert"), bei einer echten Teilmenge übernimmt
    // `emptiedMachineIds` unten (die RPC lehnt eine nicht-null `machine_id`
    // zusammen mit einer nicht-leeren Liste ab). Ohne Checkboxen unverändert
    // das, was der Bediener im Picker gewählt hat (auch im Mehrfach-
    // Rücklage-Modus) — nicht an isMultiMachine gekoppelt, `null` ist dort
    // weiterhin ein legitimer, expliziter Wert.
    machineId: showMachineCheckboxes.value ? null : form.value.machine_id,
    // Nur bei einer echten Teilmenge gesendet — "alle" oder "keiner"
    // angehakt bleiben die heutige NULL-Darstellung, siehe oben.
    emptiedMachineIds: isSubsetSelection.value ? checkedMachineList.value : [],
    // Im Mehrfach-Modus geht die Rücklage ausschließlich über `floats` —
    // floatBack bleibt 0, damit die RPC-seitige "p_float_back und p_floats
    // schließen sich aus"-Prüfung nie anschlägt.
    floatBack: isMultiMachine.value ? 0 : floatBack.value,
    floats: isMultiMachine.value ? multiFloats.value.filter(f => f.amount > 0) : [],
    description: form.value.description,
  })
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordWithdrawal')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div class="rounded-lg border bg-muted/50 p-3">
        <div class="text-sm text-muted-foreground">{{ t('cashBook.expectedFromMachines') }}</div>
        <div class="text-lg font-bold tabular-nums">
          {{ theoreticalCash ? formatCurrency(theoreticalCash.cash_sales_since) : '—' }}
        </div>
        <div v-if="theoreticalCash?.machines?.length" class="mt-2 space-y-0.5">
          <div v-for="m in theoreticalCash.machines" :key="m.machine_id" class="text-xs text-muted-foreground">
            {{ m.machine_name || 'Automat' }}: +{{ formatCurrency(m.cash_sales) }}
          </div>
        </div>
        <p class="mt-2 text-xs text-muted-foreground italic">
          {{ t('cashBook.expectedFromMachinesHint') }}
        </p>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.countedAmount') }} (EUR)</label>
        <input
          v-model.number="form.counted_amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div
        v-if="form.counted_amount > 0 && theoreticalCash && Math.abs(difference) > 0.001"
        class="text-sm text-muted-foreground"
      >
        {{ t('cashBook.differenceLabel') }}: {{ formatCurrency(difference) }}
      </div>

      <!-- Einzelfall: ein Feld, wie bisher. `type="text"` statt `number` —
           siehe `parsedAmountIfValid`: ein unparsbarer Wert muss sichtbar
           bleiben statt still als 0 zu landen. -->
      <div v-if="!isMultiMachine">
        <label class="text-sm font-medium">{{ t('cashBook.floatBack') }} (EUR)</label>
        <input
          v-model="floatBackText"
          type="text" inputmode="decimal"
          :class="[
            'mt-1 h-9 w-full rounded-md border bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring',
            floatBackIsValid ? 'border-input' : 'border-red-500 text-red-600',
          ]"
        />
        <p v-if="!floatBackIsValid" class="mt-1 text-xs text-red-600">{{ t('cashBook.amountInvalid') }}</p>
        <p v-else class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.floatBackHint') }}</p>
      </div>

      <!-- Mehrfach-Modus: eine Zeile je Automat der Theoretical-Cash-Aufschlüsselung,
           damit sich die Rücklage nicht mehr auf einen einzigen Automaten
           zwingen lässt, wenn tatsächlich mehrere geleert wurden. -->
      <div v-else>
        <label class="text-sm font-medium">{{ t('cashBook.floatBack') }} (EUR)</label>
        <div class="mt-1 space-y-2">
          <div
            v-for="m in theoreticalCash?.machines ?? []"
            :key="m.machine_id"
            class="flex items-center gap-2"
          >
            <span class="flex-1 truncate text-sm">{{ m.machine_name || 'Automat' }}</span>
            <input
              v-model="multiFloatTexts[m.machine_id]"
              type="text" inputmode="decimal"
              :class="[
                'h-9 w-28 rounded-md border bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring',
                parsedAmountIfValid(multiFloatTexts[m.machine_id] ?? '') !== null ? 'border-input' : 'border-red-500 text-red-600',
              ]"
            />
          </div>
        </div>
        <p v-if="!multiFloatsAreValid" class="mt-1 text-xs text-red-600">{{ t('cashBook.amountInvalid') }}</p>
        <p v-else class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.floatBackHint') }}</p>
      </div>

      <div v-if="totalFloatBack > 0" class="text-sm text-muted-foreground">
        {{ t('cashBook.netToBox') }}: {{ formatCurrency(netToBox) }}
      </div>

      <!-- Automatenauswahl für die Entnahme selbst — bewusst unabhängig von
           isMultiMachine (Pre-Branch-Bedingung, siehe fix-wave-e-report.md):
           die Rücklage kann pro Automat erfasst werden, ohne dass das die
           Entnahme-Zuordnung selbst auf NULL zwingt. Bei mehr als einem
           zugeordneten Automaten UND trackPerMachine an (showMachineCheckboxes)
           ersetzen Checkboxen das Dropdown, damit sich eine Tour ausdrücken
           lässt, die nur einen Teil der Automaten geleert hat
           (20260807000900, p_emptied_machine_ids). -->
      <div v-if="showMachineCheckboxes">
        <label class="text-sm font-medium">{{ t('cashBook.fromMachine') }}</label>
        <div class="mt-1 space-y-1.5">
          <label
            v-for="m in assignedMachines"
            :key="m.id"
            class="flex items-center gap-2 text-sm"
          >
            <input
              v-model="checkedMachineIds[m.id]"
              type="checkbox"
              class="size-4 rounded border-input"
            />
            <span>{{ m.name || m.id.slice(0, 8) }}</span>
          </label>
        </div>
        <p v-if="isSubsetSelection" class="mt-1 text-xs text-muted-foreground">
          {{ t('cashBook.withdrawalEmptiesSelectedMachines') }}
        </p>
        <p v-else class="mt-1 text-xs text-muted-foreground">
          {{ t('cashBook.withdrawalEmptiesAllMachines') }}
        </p>
      </div>
      <div v-else-if="showMachinePicker">
        <label class="text-sm font-medium">
          {{ t('cashBook.fromMachine') }}
          <span v-if="machineRequired" class="text-red-600">*</span>
        </label>
        <select
          v-model="form.machine_id"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option :value="null">—</option>
          <option v-for="m in assignedMachines" :key="m.id" :value="m.id">
            {{ m.name || m.id.slice(0, 8) }}
          </option>
        </select>
        <p v-if="trackPerMachine && form.machine_id === null" class="mt-1 text-xs text-muted-foreground">
          {{ t('cashBook.withdrawalEmptiesAllMachines') }}
        </p>
      </div>
      <p v-else-if="machineRequired && assignedMachines.length === 0" class="text-xs text-muted-foreground">
        {{ t('cashBook.noAssignedMachineHint') }}
      </p>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
        <input
          v-model="form.description"
          type="text"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div v-if="error" class="rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-400">
        {{ error }}
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="submitting || !canSubmit"
                class="h-9 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50">
          {{ submitting ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
