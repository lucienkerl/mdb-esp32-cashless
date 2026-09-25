package xyz.vmflow.ui.deals

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import kotlinx.datetime.LocalDate
import xyz.vmflow.R
import xyz.vmflow.data.DealValidity
import xyz.vmflow.data.DealValidityStatus
import xyz.vmflow.data.DealVerdict
import xyz.vmflow.data.DealEk
import xyz.vmflow.ui.theme.DealUpcomingContainerDark
import xyz.vmflow.ui.theme.DealUpcomingContainerLight
import xyz.vmflow.ui.theme.DealUpcomingContentDark
import xyz.vmflow.ui.theme.DealUpcomingContentLight
import xyz.vmflow.ui.theme.StockGreen
import xyz.vmflow.ui.theme.StockOrange
import xyz.vmflow.ui.theme.StockRed
import java.text.NumberFormat
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Currency
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** Prices are EUR throughout the backend (`deal_price` is gross EUR). */
internal fun formatEuro(value: Double): String =
    NumberFormat.getCurrencyInstance(Locale.GERMANY).apply { currency = Currency.getInstance("EUR") }.format(value)

private fun LocalDate.toJava(): java.time.LocalDate = java.time.LocalDate.of(year, monthNumber, dayOfMonth)

/** "Mo., 28.09." — weekday first, since "is it Monday yet?" decides the trip. */
internal fun shortDay(date: LocalDate): String =
    date.toJava().format(DateTimeFormatter.ofPattern("EEE, dd.MM.", Locale.getDefault()))

/** "Montag, 28. September 2026" for the detail notice. */
internal fun longDay(date: LocalDate): String =
    date.toJava().format(DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL).withLocale(Locale.getDefault()))

@Composable
internal fun startsInLabel(days: Int): String = pluralStringResource(R.plurals.deals_starts_in_days, days, days)

@Composable
internal fun validFromLabel(date: LocalDate): String = stringResource(R.string.deals_valid_from, shortDay(date))

/** "valid from Mon, 28.09. · in 3 days" for an upcoming deal; null otherwise. */
@Composable
internal fun upcomingLabel(validity: DealValidity): String? {
    if (validity.status != DealValidityStatus.UPCOMING) return null
    val from = validity.from ?: return null
    val rel = validity.startsInDays?.let { startsInLabel(it) }
    return listOfNotNull(validFromLabel(from), rel).joinToString(" · ")
}

/** Short status text for deals that are valid today (or expired). */
@Composable
internal fun validityLabel(validity: DealValidity): String = when (validity.status) {
    DealValidityStatus.UPCOMING -> validity.from?.let { validFromLabel(it) } ?: stringResource(R.string.deals_not_valid_yet)
    DealValidityStatus.EXPIRED -> stringResource(R.string.deals_status_expired)
    DealValidityStatus.EXPIRING -> {
        val left = validity.daysLeft ?: 0
        if (left == 0) stringResource(R.string.deals_last_day) else pluralStringResource(R.plurals.deals_days_left, left, left)
    }
    DealValidityStatus.ACTIVE ->
        validity.until?.let { stringResource(R.string.deals_valid_until, shortDay(it)) }
            ?: stringResource(R.string.deals_status_active)
}

internal fun validityColor(status: DealValidityStatus, upcomingContent: Color): Color = when (status) {
    DealValidityStatus.UPCOMING -> upcomingContent
    DealValidityStatus.ACTIVE -> StockGreen
    DealValidityStatus.EXPIRING -> StockOrange
    DealValidityStatus.EXPIRED -> Color.Gray
}

internal data class UpcomingColors(val container: Color, val content: Color)

@Composable
internal fun upcomingColors(): UpcomingColors =
    if (isSystemInDarkTheme()) {
        UpcomingColors(DealUpcomingContainerDark, DealUpcomingContentDark)
    } else {
        UpcomingColors(DealUpcomingContainerLight, DealUpcomingContentLight)
    }

internal data class EkPill(val text: String, val color: Color)

/** Card pill for the best EK verdict, mirroring iOS `DealsView.ekPill(for:)`. */
@Composable
internal fun ekPill(ek: DealEk): EkPill? {
    val verdict = ek.bestVerdict ?: return null
    val pct = ek.bestDeltaPct?.let { abs(it.roundToInt()) }
    return when (verdict) {
        DealVerdict.GOOD_BEST, DealVerdict.GOOD -> EkPill(
            if (pct != null) stringResource(R.string.deals_ek_below_pct, pct) else stringResource(R.string.deals_ek_below),
            StockGreen,
        )
        DealVerdict.SIMILAR -> EkPill(stringResource(R.string.deals_ek_similar), StockOrange)
        DealVerdict.WORSE -> EkPill(
            if (pct != null) stringResource(R.string.deals_ek_above_pct, pct) else stringResource(R.string.deals_ek_above),
            StockRed,
        )
        else -> null
    }
}
