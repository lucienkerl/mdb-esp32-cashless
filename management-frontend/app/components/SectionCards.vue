<script setup lang="ts">
import { IconTrendingUp, IconTrendingDown, IconAlertTriangle, IconPackages } from "@tabler/icons-vue"

import { Badge } from '@/components/ui/badge'
import { formatCurrency } from '@/lib/utils'
import {
  Card,
  CardAction,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

const props = defineProps<{
  todaySales: number
  todaySalesCount: number
  yesterdayRevenue: number
  weekSales: number
  lastWeekSales: number
  monthSales: number
  lastMonthSales: number
  stockCritical: number
  stockLow: number
  warehouseBelowMin: number
  warehouseExpiringSoon: number
  todaySparkline: number[]
  weekSparkline: number[]
  monthSparkline: number[]
}>()

function pctChange(current: number, previous: number): number | null {
  if (previous === 0) return current > 0 ? 100 : null
  return Math.round(((current - previous) / previous) * 100)
}

const todayVsYesterday = computed(() => pctChange(props.todaySales, props.yesterdayRevenue))
const weekVsLastWeek = computed(() => pctChange(props.weekSales, props.lastWeekSales))
const monthVsLastMonth = computed(() => pctChange(props.monthSales, props.lastMonthSales))

const stockTotal = computed(() => props.stockCritical + props.stockLow)

/** Build an SVG path + fill area from an array of values */
function sparklinePath(values: number[], width: number, height: number): { line: string; area: string } {
  if (values.length < 2) return { line: '', area: '' }
  const max = Math.max(...values, 1)
  const stepX = width / (values.length - 1)
  const points = values.map((v, i) => {
    const x = i * stepX
    const y = height - (v / max) * height * 0.8 - height * 0.05
    return `${x.toFixed(1)},${y.toFixed(1)}`
  })
  const line = `M${points.join(' L')}`
  const area = `${line} L${width},${height} L0,${height} Z`
  return { line, area }
}
</script>

<template>
  <div class="*:data-[slot=card]:from-primary/5 *:data-[slot=card]:to-card dark:*:data-[slot=card]:bg-card grid grid-cols-1 gap-4 px-4 *:data-[slot=card]:bg-gradient-to-t *:data-[slot=card]:shadow-xs lg:px-6 @xl/main:grid-cols-2 @5xl/main:grid-cols-3">
    <!-- Today's Revenue -->
    <Card class="@container/card relative overflow-hidden">
      <svg v-if="todaySparkline.length >= 2" class="pointer-events-none absolute inset-0 h-full w-full" preserveAspectRatio="none" viewBox="0 0 200 100">
        <defs>
          <linearGradient id="spark-today-vfade" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="currentColor" stop-opacity="0.1" />
            <stop offset="100%" stop-color="currentColor" stop-opacity="0" />
          </linearGradient>
          <linearGradient id="spark-today-hfade" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stop-color="white" stop-opacity="0" />
            <stop offset="40%" stop-color="white" stop-opacity="0" />
            <stop offset="100%" stop-color="white" stop-opacity="1" />
          </linearGradient>
          <mask id="spark-today-mask">
            <rect width="200" height="100" fill="url(#spark-today-hfade)" />
          </mask>
        </defs>
        <g mask="url(#spark-today-mask)">
          <path :d="sparklinePath(todaySparkline, 200, 100).area" fill="url(#spark-today-vfade)" class="text-primary" />
          <path :d="sparklinePath(todaySparkline, 200, 100).line" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="text-primary opacity-20" />
        </g>
      </svg>
      <CardHeader class="relative">
        <CardDescription>Today's Revenue</CardDescription>
        <CardTitle class="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
          {{ formatCurrency(todaySales) }}
        </CardTitle>
        <CardAction>
          <Badge v-if="todayVsYesterday != null" :variant="'outline'" :class="todayVsYesterday >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'">
            <component :is="todayVsYesterday >= 0 ? IconTrendingUp : IconTrendingDown" class="size-4" />
            {{ todayVsYesterday >= 0 ? '+' : '' }}{{ todayVsYesterday }}%
          </Badge>
          <Badge v-else variant="outline">Today</Badge>
        </CardAction>
      </CardHeader>
      <CardFooter class="relative flex-col items-start gap-1.5 text-sm">
        <div class="text-muted-foreground">{{ todaySalesCount }} sale{{ todaySalesCount !== 1 ? 's' : '' }} &middot; vs. yesterday</div>
      </CardFooter>
    </Card>

    <!-- This Week -->
    <Card class="@container/card relative overflow-hidden">
      <svg v-if="weekSparkline.length >= 2" class="pointer-events-none absolute inset-0 h-full w-full" preserveAspectRatio="none" viewBox="0 0 200 100">
        <defs>
          <linearGradient id="spark-week-vfade" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="currentColor" stop-opacity="0.1" />
            <stop offset="100%" stop-color="currentColor" stop-opacity="0" />
          </linearGradient>
          <linearGradient id="spark-week-hfade" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stop-color="white" stop-opacity="0" />
            <stop offset="40%" stop-color="white" stop-opacity="0" />
            <stop offset="100%" stop-color="white" stop-opacity="1" />
          </linearGradient>
          <mask id="spark-week-mask">
            <rect width="200" height="100" fill="url(#spark-week-hfade)" />
          </mask>
        </defs>
        <g mask="url(#spark-week-mask)">
          <path :d="sparklinePath(weekSparkline, 200, 100).area" fill="url(#spark-week-vfade)" class="text-primary" />
          <path :d="sparklinePath(weekSparkline, 200, 100).line" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="text-primary opacity-20" />
        </g>
      </svg>
      <CardHeader class="relative">
        <CardDescription>This Week</CardDescription>
        <CardTitle class="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
          {{ formatCurrency(weekSales) }}
        </CardTitle>
        <CardAction>
          <Badge v-if="weekVsLastWeek != null" :variant="'outline'" :class="weekVsLastWeek >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'">
            <component :is="weekVsLastWeek >= 0 ? IconTrendingUp : IconTrendingDown" class="size-4" />
            {{ weekVsLastWeek >= 0 ? '+' : '' }}{{ weekVsLastWeek }}%
          </Badge>
          <Badge v-else variant="outline">7 days</Badge>
        </CardAction>
      </CardHeader>
      <CardFooter class="relative flex-col items-start gap-1.5 text-sm">
        <div class="text-muted-foreground">vs. last week: {{ formatCurrency(lastWeekSales) }}</div>
      </CardFooter>
    </Card>

    <!-- This Month -->
    <Card class="@container/card relative overflow-hidden">
      <svg v-if="monthSparkline.length >= 2" class="pointer-events-none absolute inset-0 h-full w-full" preserveAspectRatio="none" viewBox="0 0 200 100">
        <defs>
          <linearGradient id="spark-month-vfade" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="currentColor" stop-opacity="0.1" />
            <stop offset="100%" stop-color="currentColor" stop-opacity="0" />
          </linearGradient>
          <linearGradient id="spark-month-hfade" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stop-color="white" stop-opacity="0" />
            <stop offset="40%" stop-color="white" stop-opacity="0" />
            <stop offset="100%" stop-color="white" stop-opacity="1" />
          </linearGradient>
          <mask id="spark-month-mask">
            <rect width="200" height="100" fill="url(#spark-month-hfade)" />
          </mask>
        </defs>
        <g mask="url(#spark-month-mask)">
          <path :d="sparklinePath(monthSparkline, 200, 100).area" fill="url(#spark-month-vfade)" class="text-primary" />
          <path :d="sparklinePath(monthSparkline, 200, 100).line" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="text-primary opacity-20" />
        </g>
      </svg>
      <CardHeader class="relative">
        <CardDescription>This Month</CardDescription>
        <CardTitle class="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
          {{ formatCurrency(monthSales) }}
        </CardTitle>
        <CardAction>
          <Badge v-if="monthVsLastMonth != null" :variant="'outline'" :class="monthVsLastMonth >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'">
            <component :is="monthVsLastMonth >= 0 ? IconTrendingUp : IconTrendingDown" class="size-4" />
            {{ monthVsLastMonth >= 0 ? '+' : '' }}{{ monthVsLastMonth }}%
          </Badge>
          <Badge v-else variant="outline">Month</Badge>
        </CardAction>
      </CardHeader>
      <CardFooter class="relative flex-col items-start gap-1.5 text-sm">
        <div class="text-muted-foreground">vs. last month: {{ formatCurrency(lastMonthSales) }}</div>
      </CardFooter>
    </Card>

    <!-- Stock Alerts (only shown when there are alerts) -->
    <Card v-if="stockTotal > 0" class="@container/card">
      <CardHeader>
        <CardDescription>Stock Alerts</CardDescription>
        <CardTitle class="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
          {{ stockTotal }}
        </CardTitle>
        <CardAction>
          <Badge variant="outline" class="text-red-600 dark:text-red-400">
            <IconAlertTriangle class="size-4" />
            Action
          </Badge>
        </CardAction>
      </CardHeader>
      <CardFooter class="flex-col items-start gap-1.5 text-sm">
        <div class="text-muted-foreground">
          <span v-if="stockCritical > 0" class="text-red-600 dark:text-red-400">{{ stockCritical }} critical</span>
          <span v-if="stockCritical > 0 && stockLow > 0"> &middot; </span>
          <span v-if="stockLow > 0" class="text-amber-600 dark:text-amber-400">{{ stockLow }} low</span>
        </div>
      </CardFooter>
    </Card>

    <!-- Warehouse Alerts (only shown when there are alerts) -->
    <Card v-if="warehouseBelowMin > 0 || warehouseExpiringSoon > 0" class="@container/card">
      <CardHeader>
        <CardDescription>Warehouse</CardDescription>
        <CardTitle class="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
          {{ warehouseBelowMin + warehouseExpiringSoon }}
        </CardTitle>
        <CardAction>
          <Badge variant="outline" class="text-amber-600 dark:text-amber-400">
            <IconPackages class="size-4" />
            Alert
          </Badge>
        </CardAction>
      </CardHeader>
      <CardFooter class="flex-col items-start gap-1.5 text-sm">
        <div class="text-muted-foreground">
          <span v-if="warehouseBelowMin > 0">{{ warehouseBelowMin }} below min</span>
          <span v-if="warehouseBelowMin > 0 && warehouseExpiringSoon > 0"> &middot; </span>
          <span v-if="warehouseExpiringSoon > 0">{{ warehouseExpiringSoon }} expiring</span>
        </div>
      </CardFooter>
    </Card>
  </div>
</template>
