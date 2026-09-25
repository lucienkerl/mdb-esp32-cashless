package xyz.vmflow.ui.theme

import androidx.compose.ui.graphics.Color

// VMflow brand colors
val VMflowBlue = Color(0xFF1565C0)
val VMflowBlueDark = Color(0xFF0D47A1)
val VMflowBlueLight = Color(0xFF42A5F5)
val VMflowBlueSurface = Color(0xFFE3F2FD)

// Light theme
val md_theme_light_primary = Color(0xFF1565C0)
val md_theme_light_onPrimary = Color(0xFFFFFFFF)
val md_theme_light_primaryContainer = Color(0xFFD6E3FF)
val md_theme_light_onPrimaryContainer = Color(0xFF001B3E)
val md_theme_light_secondary = Color(0xFF555F71)
val md_theme_light_onSecondary = Color(0xFFFFFFFF)
val md_theme_light_secondaryContainer = Color(0xFFD9E3F8)
val md_theme_light_onSecondaryContainer = Color(0xFF121C2B)
val md_theme_light_tertiary = Color(0xFF6E5676)
val md_theme_light_onTertiary = Color(0xFFFFFFFF)
val md_theme_light_tertiaryContainer = Color(0xFFF8D8FE)
val md_theme_light_onTertiaryContainer = Color(0xFF27132F)
val md_theme_light_error = Color(0xFFBA1A1A)
val md_theme_light_onError = Color(0xFFFFFFFF)
val md_theme_light_errorContainer = Color(0xFFFFDAD6)
val md_theme_light_onErrorContainer = Color(0xFF410002)
val md_theme_light_background = Color(0xFFFAFAFD)
val md_theme_light_onBackground = Color(0xFF1A1B1E)
val md_theme_light_surface = Color(0xFFFAFAFD)
val md_theme_light_onSurface = Color(0xFF1A1B1E)
val md_theme_light_surfaceVariant = Color(0xFFE0E2EC)
val md_theme_light_onSurfaceVariant = Color(0xFF44474E)
val md_theme_light_outline = Color(0xFF74777F)
val md_theme_light_outlineVariant = Color(0xFFC4C6D0)

// Dark theme
val md_theme_dark_primary = Color(0xFFA9C7FF)
val md_theme_dark_onPrimary = Color(0xFF003063)
val md_theme_dark_primaryContainer = Color(0xFF00468C)
val md_theme_dark_onPrimaryContainer = Color(0xFFD6E3FF)
val md_theme_dark_secondary = Color(0xFFBDC7DC)
val md_theme_dark_onSecondary = Color(0xFF273141)
val md_theme_dark_secondaryContainer = Color(0xFF3D4758)
val md_theme_dark_onSecondaryContainer = Color(0xFFD9E3F8)
val md_theme_dark_tertiary = Color(0xFFDBBDE2)
val md_theme_dark_onTertiary = Color(0xFF3E2846)
val md_theme_dark_tertiaryContainer = Color(0xFF553F5D)
val md_theme_dark_onTertiaryContainer = Color(0xFFF8D8FE)
val md_theme_dark_error = Color(0xFFFFB4AB)
val md_theme_dark_onError = Color(0xFF690005)
val md_theme_dark_errorContainer = Color(0xFF93000A)
val md_theme_dark_onErrorContainer = Color(0xFFFFDAD6)
val md_theme_dark_background = Color(0xFF121316)
val md_theme_dark_onBackground = Color(0xFFE3E2E6)
val md_theme_dark_surface = Color(0xFF121316)
val md_theme_dark_onSurface = Color(0xFFE3E2E6)
val md_theme_dark_surfaceVariant = Color(0xFF44474E)
val md_theme_dark_onSurfaceVariant = Color(0xFFC4C6D0)
val md_theme_dark_outline = Color(0xFF8E9099)
val md_theme_dark_outlineVariant = Color(0xFF44474E)

// Stock colors
val StockGreen = Color(0xFF4CAF50)
val StockYellow = Color(0xFFFFC107)
val StockOrange = Color(0xFFFF9800)
val StockRed = Color(0xFFF44336)

val OnlineGreen = Color(0xFF4CAF50)
val OfflineGray = Color(0xFF9E9E9E)

// ─── Analysis slot tiers ────────────────────────────────────────────────────
// Deliberately fixed, distinct hues rather than scheme roles. The brand
// scheme's primary/secondary/tertiary sit close together, so deriving the five
// tiers from them rendered as near-identical tones in dark mode — which defeats
// the whole point of a grid you are meant to read at a glance. Each tier gets a
// light- and a dark-surface variant so contrast holds in both themes.
val TierStrongLight = Color(0xFF2E7D32)
val TierStrongDark = Color(0xFF66BB6A)
val TierOkLight = Color(0xFF0277BD)
val TierOkDark = Color(0xFF4FC3F7)
val TierTestingLight = Color(0xFF6A1B9A)
val TierTestingDark = Color(0xFFBA68C8)
val TierWeakLight = Color(0xFFEF6C00)
val TierWeakDark = Color(0xFFFFB74D)
val TierDeadLight = Color(0xFFC62828)
val TierDeadDark = Color(0xFFEF5350)

// ─── Refill review reasons ──────────────────────────────────────────────────
// The four reasons a slot lands in the pre-tour review (`ReplacementReason`),
// each in its own hue so the badges stay tellable apart at a glance — same
// argument as the tier block above, and the same reason they are fixed tokens
// rather than `primary`/`secondary`/`tertiary` roles (which collapse into
// near-identical tones in this brand's dark scheme).
//
// The hues match iOS `ReviewStepView.badgeColor(for:)` (red / orange / purple
// / blue). Deliberately *their own* constants rather than aliases of the tier
// tokens above: the two palettes mean unrelated things (a product's sales
// performance vs. why a slot needs attention), and re-tuning one must not
// silently repaint the other.
val ReasonDiscontinuedLight = Color(0xFFC62828)
val ReasonDiscontinuedDark = Color(0xFFEF5350)
val ReasonExpiredLight = Color(0xFFEF6C00)
val ReasonExpiredDark = Color(0xFFFFB74D)
val ReasonNoStockLight = Color(0xFF6A1B9A)
val ReasonNoStockDark = Color(0xFFBA68C8)
val ReasonUnassignedLight = Color(0xFF0277BD)
val ReasonUnassignedDark = Color(0xFF4FC3F7)

// ─── Deals: "not valid yet" ─────────────────────────────────────────────────
// Amber, not blue: blue next to a green price read as "valid, go", which is
// exactly the misreading this marker has to prevent (people drove to the store
// for an offer that only started days later). Same hue family as the web's
// amber badge and the iOS orange capsule. Container + content pairs per theme
// so the text keeps its contrast.
val DealUpcomingContainerLight = Color(0xFFFFE0B2)
val DealUpcomingContentLight = Color(0xFF7A3E00)
val DealUpcomingContainerDark = Color(0xFF5A3300)
val DealUpcomingContentDark = Color(0xFFFFCC80)
