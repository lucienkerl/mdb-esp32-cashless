package de.kerlhandel.vmflow.ui.common

import androidx.compose.runtime.staticCompositionLocalOf

/** Composition local carrying the current Supabase base URL (changes when server switches). */
val LocalSupabaseUrl = staticCompositionLocalOf<String> {
    error("LocalSupabaseUrl not provided")
}
