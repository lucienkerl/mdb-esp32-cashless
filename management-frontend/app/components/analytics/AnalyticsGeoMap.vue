<!--
  AnalyticsGeoMap
  ---------------
  Leaflet bubble map for the Analytics > Machines tab (Task 4.3 / Phase 4).

  Renders a circle marker per machine at its (lat, lng). Bubble RADIUS is a
  log-ish scale on revenue so a few high-revenue outliers don't overwhelm the
  rest. Bubble COLOR is the conversion percentile within the input set —
  bottom third red, middle third yellow, top third green. This trades absolute
  precision for a quick visual scan: "where are my underperformers?".

  SSR-safe pattern (mirrors LocationPicker.vue):
    - Type-only `import type { ... } from 'leaflet'` — erased at runtime
    - `import('leaflet')` + CSS import inside `onMounted` so SSR build never
      touches `window` / `document`
    - `destroyed` guard against unmount races during dynamic imports
    - `onBeforeUnmount` clears the map and nulls the handle

  We watch the `machines` prop — when the parent re-fetches, we tear down the
  existing layer group and rebuild markers + bounds. Cheap because the marker
  count is bounded by the company's machine count.
-->
<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
// Type-only imports — erased at runtime, SSR-safe.
import type { Map as LMap, LayerGroup as LLayerGroup, CircleMarker as LCircleMarker } from 'leaflet'

interface MachinePoint {
  id: string
  name: string
  lat: number | null
  lng: number | null
  revenue: number
  conversion_pct: number | null
}

const props = defineProps<{
  machines: MachinePoint[]
}>()

const mapEl = ref<HTMLDivElement | null>(null)
let map: LMap | null = null
let markerGroup: LLayerGroup | null = null
// Holds the dynamically imported Leaflet default export so later functions can use it.
let L: typeof import('leaflet') | null = null
// Guard against unmount races: initMap awaits dynamic imports of leaflet + CSS;
// if the component is destroyed mid-init, we must NOT create a map on a stale node.
let destroyed = false

/**
 * Compute the 33rd and 66th percentiles of the conversion values present in
 * the input set. Used to pick a tri-color palette — bottom/middle/top third.
 * Machines with null conversion fall through to the "low" bucket since we
 * can't classify them; this matches the pessimistic UX intent.
 */
function conversionThresholds(points: MachinePoint[]): { low: number; high: number } {
  const vals = points
    .map((p) => p.conversion_pct)
    .filter((v): v is number => typeof v === 'number')
    .sort((a, b) => a - b)
  if (vals.length === 0) return { low: 0, high: 0 }
  const lo = vals[Math.floor(vals.length * 0.33)] ?? 0
  const hi = vals[Math.floor(vals.length * 0.66)] ?? 0
  return { low: lo, high: hi }
}

/**
 * Bubble color by conversion percentile against the input set.
 * Below 33rd → red, between 33rd and 66th → yellow, above 66th → green.
 * Null conversion falls into the "low" bucket — see thresholds().
 */
function colorFor(conv: number | null, t: { low: number; high: number }): string {
  const v = conv ?? -1
  if (v < t.low) return '#ef4444'  // red-500
  if (v < t.high) return '#eab308' // yellow-500
  return '#22c55e'                  // green-500
}

/**
 * Bubble radius in pixels. sqrt of revenue for diminishing returns; clamped
 * to a readable range so a tiny machine still has a visible dot and a giant
 * one doesn't swallow the map.
 */
function radiusFor(revenue: number): number {
  return Math.max(8, Math.min(40, 8 + Math.sqrt(revenue) / 5))
}

async function initMap() {
  if (!mapEl.value) return

  // Dynamic imports — only run on the client, SSR build won't touch window/document.
  const leaflet = await import('leaflet')
  if (destroyed) return
  await import('leaflet/dist/leaflet.css')
  if (destroyed || !mapEl.value) return
  L = leaflet.default ?? (leaflet as unknown as typeof import('leaflet'))

  // Default to Dresden (matches LocationPicker default) until we have machines.
  map = L.map(mapEl.value).setView([51.05, 13.74], 13)

  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>',
  }).addTo(map)

  markerGroup = L.layerGroup().addTo(map)
  renderMarkers()
}

function renderMarkers() {
  if (!map || !L || !markerGroup) return
  markerGroup.clearLayers()

  // Filter out machines without coordinates — we can't render those on a map.
  const points = props.machines.filter(
    (m): m is MachinePoint & { lat: number; lng: number } => m.lat != null && m.lng != null,
  )
  if (points.length === 0) {
    map.setView([51.05, 13.74], 13)
    return
  }

  const t = conversionThresholds(points)
  const coords: Array<[number, number]> = []

  for (const p of points) {
    const color = colorFor(p.conversion_pct, t)
    const radius = radiusFor(p.revenue)
    const marker: LCircleMarker = L.circleMarker([p.lat, p.lng], {
      radius,
      color,
      fillColor: color,
      fillOpacity: 0.55,
      weight: 2,
    })
    const conv = p.conversion_pct == null ? '—' : `${p.conversion_pct.toFixed(1)}%`
    marker.bindTooltip(`${p.name}: ${p.revenue.toFixed(2)} EUR / ${conv}`)
    marker.addTo(markerGroup)
    coords.push([p.lat, p.lng])
  }

  // Auto-fit bounds when we have at least one point. Padding keeps bubbles
  // from being clipped at the edge of the viewport.
  map.fitBounds(L.latLngBounds(coords), { padding: [24, 24] })
}

onMounted(() => {
  void initMap()
})

onBeforeUnmount(() => {
  destroyed = true
  if (map) {
    map.remove()
    map = null
  }
  markerGroup = null
})

// Re-render markers when the parent updates the machines list (e.g. filter
// change). We don't tear down the map itself — just clear+re-add markers.
watch(
  () => props.machines,
  () => {
    renderMarkers()
  },
  { deep: true },
)
</script>

<template>
  <div class="rounded-xl border bg-card overflow-hidden" data-testid="analytics-geomap">
    <div ref="mapEl" class="h-[400px] w-full" />
  </div>
</template>
