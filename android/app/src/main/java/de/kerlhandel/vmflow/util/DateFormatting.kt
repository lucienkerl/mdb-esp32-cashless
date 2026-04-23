package de.kerlhandel.vmflow.util

import kotlinx.datetime.Clock
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.DayOfWeek
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.daysUntil
import kotlinx.datetime.minus
import kotlinx.datetime.plus
import kotlinx.datetime.toInstant
import kotlinx.datetime.toLocalDateTime
import java.text.NumberFormat
import java.util.Locale

object DateFormatting {
    private val currencyFormatter: NumberFormat by lazy {
        NumberFormat.getCurrencyInstance(Locale.GERMANY).apply {
            minimumFractionDigits = 2
            maximumFractionDigits = 2
        }
    }

    fun formatCurrency(value: Double): String = currencyFormatter.format(value)

    fun formatCurrencyCompact(amount: Double): String = when {
        amount >= 1_000_000 -> "%.1fM".format(amount / 1_000_000)
        amount >= 1_000 -> "%.0fk".format(amount / 1_000)
        else -> "%.0f".format(amount)
    }

    fun formatTimeHms(instant: Instant, tz: TimeZone = TimeZone.currentSystemDefault()): String {
        val local = instant.toLocalDateTime(tz)
        return "%02d:%02d:%02d".format(local.hour, local.minute, local.second)
    }

    /** Relative "time ago" — mirrors iOS timeAgo in [DashboardView.swift]. */
    fun timeAgoMinutes(instant: Instant, now: Instant = Clock.System.now()): Long =
        (now - instant).inWholeMinutes.coerceAtLeast(0)
}

/** Monday-based week boundaries — matches iOS [MachineListViewModel.swift]. */
object WeekBoundaries {
    fun startOfToday(tz: TimeZone = TimeZone.currentSystemDefault()): Instant {
        val todayDate = Clock.System.now().toLocalDateTime(tz).date
        return todayDate.atStartOfDayIn(tz)
    }

    fun startOfYesterday(tz: TimeZone = TimeZone.currentSystemDefault()): Instant =
        startOfToday(tz).minus(1, DateTimeUnit.DAY, tz)

    fun startOfThisWeek(tz: TimeZone = TimeZone.currentSystemDefault()): Instant {
        val today = Clock.System.now().toLocalDateTime(tz).date
        val daysSinceMonday = (today.dayOfWeek.isoDayNumber - DayOfWeek.MONDAY.isoDayNumber + 7) % 7
        val monday = today.minus(daysSinceMonday, DateTimeUnit.DAY)
        return monday.atStartOfDayIn(tz)
    }

    fun startOfLastWeek(tz: TimeZone = TimeZone.currentSystemDefault()): Instant =
        startOfThisWeek(tz).minus(7, DateTimeUnit.DAY, tz)

    fun startOfMonth(tz: TimeZone = TimeZone.currentSystemDefault()): Instant {
        val today = Clock.System.now().toLocalDateTime(tz).date
        val firstOfMonth = LocalDate(today.year, today.month, 1)
        return firstOfMonth.atStartOfDayIn(tz)
    }

    /** Returns the past N days (inclusive of today) as LocalDate list. */
    fun pastDays(n: Int, tz: TimeZone = TimeZone.currentSystemDefault()): List<LocalDate> {
        val today = Clock.System.now().toLocalDateTime(tz).date
        return (0 until n).map { offset -> today.minus(offset, DateTimeUnit.DAY) }.reversed()
    }
}

private val DayOfWeek.isoDayNumber: Int
    get() = when (this) {
        DayOfWeek.MONDAY -> 1; DayOfWeek.TUESDAY -> 2; DayOfWeek.WEDNESDAY -> 3
        DayOfWeek.THURSDAY -> 4; DayOfWeek.FRIDAY -> 5; DayOfWeek.SATURDAY -> 6
        DayOfWeek.SUNDAY -> 7
        else -> 1
    }
