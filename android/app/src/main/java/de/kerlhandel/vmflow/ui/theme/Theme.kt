package de.kerlhandel.vmflow.ui.theme

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

// VMflow brand light palette — tuned for high contrast.
private val LightColors = lightColorScheme(
    primary = VMBlue,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDCE8FF),
    onPrimaryContainer = Color(0xFF001A41),

    secondary = Color(0xFF006C4E),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFF88F7C7),
    onSecondaryContainer = Color(0xFF002113),

    tertiary = Color(0xFF8B4A00),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFDCBF),
    onTertiaryContainer = Color(0xFF2C1600),

    error = VMRed,
    onError = Color.White,
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),

    background = Color(0xFFFBFCFF),
    onBackground = Color(0xFF1A1C1E),
    surface = Color(0xFFFBFCFF),
    onSurface = Color(0xFF1A1C1E),
    surfaceVariant = Color(0xFFE0E2EC),
    onSurfaceVariant = Color(0xFF43474E),
    surfaceContainer = Color(0xFFEFF1F4),
    surfaceContainerHigh = Color(0xFFE9EBEF),
    surfaceContainerHighest = Color(0xFFE3E5E9),

    outline = Color(0xFF73777F),
    outlineVariant = Color(0xFFC3C7CF),
)

// VMflow brand dark palette
private val DarkColors = darkColorScheme(
    primary = Color(0xFFAFC6FF),
    onPrimary = Color(0xFF002E69),
    primaryContainer = Color(0xFF004495),
    onPrimaryContainer = Color(0xFFDCE8FF),

    secondary = Color(0xFF6BDBAC),
    onSecondary = Color(0xFF003826),
    secondaryContainer = Color(0xFF005138),
    onSecondaryContainer = Color(0xFF88F7C7),

    tertiary = Color(0xFFFFB77D),
    onTertiary = Color(0xFF4A2700),
    tertiaryContainer = Color(0xFF693900),
    onTertiaryContainer = Color(0xFFFFDCBF),

    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),

    background = Color(0xFF111318),
    onBackground = Color(0xFFE2E2E9),
    surface = Color(0xFF111318),
    onSurface = Color(0xFFE2E2E9),
    surfaceVariant = Color(0xFF43474E),
    onSurfaceVariant = Color(0xFFC3C7CF),
    surfaceContainer = Color(0xFF1D2024),
    surfaceContainerHigh = Color(0xFF282A2F),
    surfaceContainerHighest = Color(0xFF33353A),

    outline = Color(0xFF8D9199),
    outlineVariant = Color(0xFF43474E),
)

@Composable
fun VMflowTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    /** Dynamic color off by default — VMflow brand identity stays stable. */
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColors
        else -> LightColors
    }

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            WindowCompat.setDecorFitsSystemWindows(window, false)
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = colorScheme.background.luminance() > 0.5f
                isAppearanceLightNavigationBars = colorScheme.background.luminance() > 0.5f
            }
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = VMflowTypography,
        content = content,
    )
}
