package de.kerlhandel.vmflow.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

private val Base = TextStyle(
    fontFamily = androidx.compose.ui.text.font.FontFamily.Default,
    fontWeight = FontWeight.Normal,
    fontSize = 16.sp,
    lineHeight = 24.sp,
)

val VMflowTypography = Typography(
    displayLarge = Base.copy(fontSize = 57.sp, fontWeight = FontWeight.Bold, lineHeight = 64.sp),
    headlineLarge = Base.copy(fontSize = 32.sp, fontWeight = FontWeight.Bold, lineHeight = 40.sp),
    headlineMedium = Base.copy(fontSize = 28.sp, fontWeight = FontWeight.Bold, lineHeight = 36.sp),
    headlineSmall = Base.copy(fontSize = 24.sp, fontWeight = FontWeight.SemiBold, lineHeight = 32.sp),
    titleLarge = Base.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, lineHeight = 28.sp),
    titleMedium = Base.copy(fontSize = 18.sp, fontWeight = FontWeight.SemiBold, lineHeight = 24.sp),
    titleSmall = Base.copy(fontSize = 14.sp, fontWeight = FontWeight.Medium, lineHeight = 20.sp),
    bodyLarge = Base.copy(fontSize = 16.sp),
    bodyMedium = Base.copy(fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = Base.copy(fontSize = 12.sp, lineHeight = 16.sp),
    labelLarge = Base.copy(fontSize = 14.sp, fontWeight = FontWeight.Medium),
    labelMedium = Base.copy(fontSize = 12.sp, fontWeight = FontWeight.Medium),
    labelSmall = Base.copy(fontSize = 11.sp, fontWeight = FontWeight.Medium),
)
