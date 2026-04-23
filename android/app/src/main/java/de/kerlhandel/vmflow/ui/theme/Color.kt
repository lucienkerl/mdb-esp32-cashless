package de.kerlhandel.vmflow.ui.theme

import androidx.compose.ui.graphics.Color

// ---- Brand CI (see BRANDING.md) ----
/** Slate-900 — brand background / engineering identity. */
val BrandSlate900 = Color(0xFF0F172A)
/** Slate-800 — slightly lifted surface on dark brand hero. */
val BrandSlate800 = Color(0xFF1E293B)
/** Lime-400 — brand accent (data-flow arrow + right half of the MDB signal). */
val BrandLime400 = Color(0xFFA3E635)

// ---- Status colors (used across the app for stock health, online indicators, etc.) ----
val VMBlue = Color(0xFF0A84FF)
val VMGreen = Color(0xFF34C759)
val VMYellow = Color(0xFFFFCC00)
val VMRed = Color(0xFFFF3B30)
val VMOrange = Color(0xFFFF9500)
val VMTeal = Color(0xFF64D2FF)
val VMPurple = Color(0xFFAF52DE)
val VMGray = Color(0xFF8E8E93)

object StatusColors {
    val success = VMGreen
    val warning = VMYellow
    val critical = VMRed
    val primary = VMBlue
    val marker = VMOrange
}
