<!--
  AnalyticsTable
  --------------
  Sortable, drill-throughable table for analytics breakdowns
  (top products, machines, categories, etc.). Generic over row shape.

  Per-column config:
    key       — row[key] is the cell value
    label     — header text (caller is responsible for i18n)
    type      — drives default formatter + alignment (number/currency/percent
                are right-aligned and tabular)
    format?   — optional custom formatter, overrides type-default
    drillTo?  — emits 'drill' { type, value, row } when the cell is clicked.
                Cell renders as a button with primary-colored text + underline
                on hover. The parent owns the navigation. The full `row` is
                included so callers can dispatch on a different field than
                the one rendered (e.g. drill by `row.key` UUID while the cell
                shows `row.label`).

  Sort state is internal — click a header to sort by it (toggle direction on
  re-click). Only the active column shows up/down arrows; others render the
  neutral sort icon. Mirrors `useTableSort` semantics but inlined to keep the
  table self-contained.

  TODO i18n: header labels, optional title — these come from props, so
  callers handle translation.
-->
<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import SortHeader from '@/components/SortHeader.vue'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'

export type Col = {
  key: string
  label: string
  format?: (v: any) => string
  type: 'number' | 'string' | 'currency' | 'percent'
  /** Render cell as a clickable drill-through; emits 'drill' on click */
  drillTo?: 'machine' | 'product' | 'category'
}

const props = defineProps<{
  rows: Record<string, any>[]
  columns: Col[]
  title?: string
}>()

const emit = defineEmits<{
  drill: [payload: { type: string; value: any; row: Record<string, any> }]
}>()

const sortKey = ref<string | null>(null)
const sortDir = ref<'asc' | 'desc'>('desc')

function toggleSort(key: string) {
  if (sortKey.value === key) {
    sortDir.value = sortDir.value === 'asc' ? 'desc' : 'asc'
  } else {
    sortKey.value = key
    sortDir.value = 'desc'
  }
}

function sortIcon(key: string): 'up' | 'down' | 'none' {
  if (sortKey.value !== key) return 'none'
  return sortDir.value === 'asc' ? 'up' : 'down'
}

const sortedRows = computed(() => {
  if (!sortKey.value) return props.rows
  const k = sortKey.value
  const dir = sortDir.value === 'asc' ? 1 : -1
  return [...props.rows].sort((a, b) => {
    const av = a[k]
    const bv = b[k]
    // null values sink to the bottom regardless of direction
    if (av == null) return 1
    if (bv == null) return -1
    if (typeof av === 'number') return (av - bv) * dir
    return String(av).localeCompare(String(bv)) * dir
  })
})

function formatCell(value: any, col: Col): string {
  if (col.format) return col.format(value)
  if (value == null) return ''
  if (col.type === 'currency') return formatCurrency(Number(value))
  if (col.type === 'percent') return `${Number(value).toFixed(1)}%`
  if (col.type === 'number') return new Intl.NumberFormat().format(Number(value))
  return String(value)
}

function isNumeric(col: Col): boolean {
  return col.type === 'number' || col.type === 'currency' || col.type === 'percent'
}
</script>

<template>
  <div data-testid="analytics-table">
    <h3 v-if="title" class="mb-2 text-sm font-medium">{{ title }}</h3>
    <div class="rounded-md border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead
              v-for="col in columns"
              :key="col.key"
              :class="isNumeric(col) ? 'text-right' : ''"
            >
              <button
                type="button"
                class="inline-flex w-full cursor-pointer select-none items-center"
                :class="isNumeric(col) ? 'justify-end' : 'justify-start'"
                @click="toggleSort(col.key)"
              >
                <SortHeader
                  :icon="sortIcon(col.key)"
                  :align="isNumeric(col) ? 'right' : 'left'"
                >
                  {{ col.label }}
                </SortHeader>
              </button>
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow v-for="(row, idx) in sortedRows" :key="idx">
            <TableCell
              v-for="col in columns"
              :key="col.key"
              :class="[
                isNumeric(col) ? 'text-right tabular-nums' : '',
              ]"
            >
              <button
                v-if="col.drillTo"
                type="button"
                class="text-primary underline-offset-2 hover:underline"
                @click="emit('drill', { type: col.drillTo, value: row[col.key], row })"
              >
                {{ formatCell(row[col.key], col) }}
              </button>
              <template v-else>
                {{ formatCell(row[col.key], col) }}
              </template>
            </TableCell>
          </TableRow>
        </TableBody>
      </Table>
    </div>
  </div>
</template>
