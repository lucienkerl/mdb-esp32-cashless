package de.kerlhandel.vmflow.ui.refill

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.RefillMachine
import de.kerlhandel.vmflow.data.model.RefillStep
import de.kerlhandel.vmflow.data.model.RefillTray
import de.kerlhandel.vmflow.data.model.TourLogEntry
import de.kerlhandel.vmflow.ui.common.ProductImage
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate800
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RefillWizardScreen(viewModel: RefillWizardViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(containerColor = MaterialTheme.colorScheme.background) { inner ->
        if (state.loading && state.machines.isEmpty()) {
            Box(
                Modifier.fillMaxSize().padding(inner),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator(color = BrandSlate900) }
            return@Scaffold
        }

        if (state.machines.isEmpty() && state.step == RefillStep.Packing) {
            Column(
                modifier = Modifier.fillMaxSize().padding(inner),
            ) {
                WizardProgressHeader(step = state.step, totalMachines = 0)
                AllStockedState(Modifier.weight(1f))
            }
            return@Scaffold
        }

        Column(modifier = Modifier.fillMaxSize().padding(inner)) {
            WizardProgressHeader(
                step = state.step,
                totalMachines = state.packed.size.coerceAtLeast(state.machines.count { it.isPacked }),
                completedMachines = state.tourLog.size,
            )

            AnimatedContent(
                targetState = state.step,
                transitionSpec = {
                    (slideInVertically { it / 8 } + fadeIn(tween(220)))
                        .togetherWith(slideOutVertically { -it / 8 } + fadeOut(tween(160)))
                },
                modifier = Modifier.weight(1f),
                label = "refillStep",
            ) { current ->
                when (current) {
                    RefillStep.Packing, RefillStep.Review -> PackStep(state, viewModel)
                    RefillStep.Refill -> RefillStepContent(state, viewModel)
                    RefillStep.Summary -> SummaryStep(state, viewModel)
                }
            }
        }
    }
}

// =============================================================
//  Progress Header — slate hero with step name + animated bar
// =============================================================

@Composable
private fun WizardProgressHeader(
    step: RefillStep,
    totalMachines: Int,
    completedMachines: Int = 0,
) {
    val stepNumber = when (step) {
        RefillStep.Review, RefillStep.Packing -> 1
        RefillStep.Refill -> 2
        RefillStep.Summary -> 3
    }
    val stepName = when (step) {
        RefillStep.Review, RefillStep.Packing -> "PACKEN"
        RefillStep.Refill -> "NACHFÜLLEN"
        RefillStep.Summary -> "ABGESCHLOSSEN"
    }
    val stepSub = when (step) {
        RefillStep.Review, RefillStep.Packing -> "Maschinen für die Tour auswählen"
        RefillStep.Refill -> "Fächer pro Maschine auffüllen"
        RefillStep.Summary -> "Tour-Log prüfen"
    }
    val targetProgress = when (step) {
        RefillStep.Review, RefillStep.Packing -> 0.0f
        RefillStep.Refill -> {
            val safe = totalMachines.coerceAtLeast(1)
            (completedMachines.toFloat() / safe).coerceIn(0f, 1f) * 0.5f + 0.35f
        }
        RefillStep.Summary -> 1.0f
    }
    val animated by animateFloatAsState(
        targetValue = targetProgress,
        animationSpec = tween(durationMillis = 700, easing = FastOutSlowInEasing),
        label = "progress",
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(BrandSlate900)
            .statusBarsPadding()
            .padding(horizontal = 20.dp)
            .padding(top = 18.dp, bottom = 20.dp),
    ) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "%02d / 03".format(stepNumber),
                    style = MaterialTheme.typography.labelMedium.copy(
                        letterSpacing = 2.sp,
                    ),
                    fontWeight = FontWeight.Bold,
                    color = BrandLime400,
                )
                Spacer(Modifier.width(10.dp))
                Box(
                    modifier = Modifier
                        .height(1.dp)
                        .weight(1f)
                        .background(Color.White.copy(alpha = 0.18f)),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    text = stepName,
                    style = MaterialTheme.typography.labelMedium.copy(
                        letterSpacing = 2.sp,
                    ),
                    fontWeight = FontWeight.Bold,
                    color = Color.White.copy(alpha = 0.7f),
                )
            }

            Spacer(Modifier.height(14.dp))

            Text(
                text = when (step) {
                    RefillStep.Refill -> "Maschine ${completedMachines + 1} von $totalMachines"
                    else -> stepSub
                },
                style = MaterialTheme.typography.headlineSmall.copy(letterSpacing = (-0.3).sp),
                fontWeight = FontWeight.Bold,
                color = Color.White,
            )

            Spacer(Modifier.height(14.dp))

            // Thin progress rail (3 segments = 3 steps)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (1..3).forEach { i ->
                    val segmentTarget = when {
                        i < stepNumber -> 1f
                        i == stepNumber -> when (step) {
                            RefillStep.Refill -> (completedMachines.toFloat() /
                                totalMachines.coerceAtLeast(1)).coerceIn(0f, 1f)
                            else -> 0.4f
                        }
                        else -> 0f
                    }
                    val animSegment by animateFloatAsState(
                        targetValue = segmentTarget,
                        animationSpec = tween(durationMillis = 500),
                        label = "seg$i",
                    )
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .height(4.dp)
                            .clip(RoundedCornerShape(50))
                            .background(Color.White.copy(alpha = 0.18f)),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(fraction = animSegment)
                                .fillMaxSize()
                                .background(BrandLime400),
                        )
                    }
                }
            }

            Spacer(Modifier.height(1.dp))
            // reference animated value so state is retained (avoids unused warning)
            if (animated < -1f) Spacer(Modifier.height(0.dp))
        }
    }
}

// =============================================================
//  Step 1 — Pack (Urgency-ranked machine selection)
// =============================================================

@Composable
private fun PackStep(state: RefillUiState, viewModel: RefillWizardViewModel) {
    val sorted = state.machines // already sorted by urgency in VM
    val packedCount = sorted.count { it.isPacked }
    val totalItems = sorted.filter { it.isPacked }.sumOf { it.totalDeficit }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = 16.dp,
                bottom = 140.dp, // room for sticky bar
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                Row(
                    modifier = Modifier.padding(bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "${sorted.size} Maschinen",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onBackground,
                        modifier = Modifier.weight(1f),
                    )
                    SelectAllChip(
                        selectedAll = packedCount == sorted.size,
                        onClick = {
                            if (packedCount == sorted.size) {
                                sorted.forEach { if (it.isPacked) viewModel.togglePacked(it.machine.id) }
                            } else {
                                viewModel.packAll()
                            }
                        },
                    )
                }
            }
            items(sorted, key = { it.machine.id }) { machine ->
                UrgencyMachineCard(
                    machine = machine,
                    onToggle = { viewModel.togglePacked(machine.machine.id) },
                )
            }
        }

        // Sticky bottom bar — summary + CTA
        PackStickyBar(
            packedMachines = packedCount,
            totalItems = totalItems,
            canStart = packedCount > 0,
            onStart = viewModel::startTour,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
private fun SelectAllChip(selectedAll: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(
                if (selectedAll) BrandSlate900 else MaterialTheme.colorScheme.surfaceContainerHigh,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.Check,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
            tint = if (selectedAll) BrandLime400 else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = if (selectedAll) "Alle ausgewählt" else "Alle auswählen",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = if (selectedAll) BrandLime400 else MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun UrgencyMachineCard(machine: RefillMachine, onToggle: () -> Unit) {
    val urgency = machineUrgency(machine)
    val ratio = (machine.stockPercent / 100f).coerceIn(0f, 1f)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(
                if (machine.isPacked) BrandSlate900
                else MaterialTheme.colorScheme.surfaceContainer,
            )
            .clickable(onClick = onToggle)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Big custom checkbox
        SelectionMark(checked = machine.isPacked)

        Spacer(Modifier.width(14.dp))

        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                UrgencyDot(urgency.color)
                Spacer(Modifier.width(7.dp))
                Text(
                    text = urgency.label,
                    style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.sp),
                    fontWeight = FontWeight.Bold,
                    color = urgency.color,
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                text = machine.machine.displayName,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = if (machine.isPacked) Color.White
                else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            Spacer(Modifier.height(6.dp))
            // Custom compact progress
            MicroStockBar(
                ratio = ratio,
                onDarkBg = machine.isPacked,
            )
        }

        Spacer(Modifier.width(12.dp))

        Column(horizontalAlignment = Alignment.End) {
            Text(
                text = "+${machine.totalDeficit}",
                style = MaterialTheme.typography.headlineSmall.copy(letterSpacing = (-0.5).sp),
                fontWeight = FontWeight.Bold,
                color = if (machine.isPacked) BrandLime400 else BrandSlate900,
            )
            Text(
                text = "${machine.traysNeedingRefill} Fächer",
                style = MaterialTheme.typography.labelSmall,
                color = if (machine.isPacked) Color.White.copy(alpha = 0.6f)
                else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private data class Urgency(val label: String, val color: Color)

@Composable
private fun machineUrgency(machine: RefillMachine): Urgency {
    val emptyTrays = machine.trays.count { it.tray.isEmpty }
    val lowTrays = machine.trays.count { it.tray.isBelowMinStock && !it.tray.isEmpty }
    return when {
        emptyTrays > 0 -> Urgency("KRITISCH · $emptyTrays LEER", VMRed)
        lowTrays > 0 -> Urgency("NIEDRIG · $lowTrays FÄCHER", VMYellow)
        else -> Urgency("AUFFÜLLEN", MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SelectionMark(checked: Boolean) {
    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(
                if (checked) BrandLime400
                else MaterialTheme.colorScheme.surfaceContainerHighest,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (checked) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = BrandSlate900,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun UrgencyDot(color: Color) {
    Box(
        modifier = Modifier
            .size(7.dp)
            .clip(CircleShape)
            .background(color),
    )
}

@Composable
private fun MicroStockBar(ratio: Float, onDarkBg: Boolean) {
    val trackColor = if (onDarkBg) Color.White.copy(alpha = 0.18f)
    else MaterialTheme.colorScheme.surfaceContainerHighest
    val fillColor = when {
        ratio < 0.25f -> VMRed
        ratio < 0.5f -> VMYellow
        else -> VMGreen
    }
    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(6.dp),
    ) {
        drawRoundRect(
            color = trackColor,
            size = size,
            cornerRadius = CornerRadius(size.height / 2, size.height / 2),
        )
        if (ratio > 0f) {
            drawRoundRect(
                color = fillColor,
                size = Size(size.width * ratio, size.height),
                cornerRadius = CornerRadius(size.height / 2, size.height / 2),
            )
        }
    }
}

@Composable
private fun PackStickyBar(
    packedMachines: Int,
    totalItems: Int,
    canStart: Boolean,
    onStart: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .navigationBarsPadding(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (packedMachines == 0) "Keine Maschinen ausgewählt"
                    else "$packedMachines Maschine${if (packedMachines == 1) "" else "n"}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = if (totalItems > 0) "$totalItems Artikel einpacken" else "—",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            Spacer(Modifier.width(12.dp))
            CtaButton(
                label = "Tour starten",
                icon = Icons.AutoMirrored.Filled.ArrowForward,
                enabled = canStart,
                onClick = onStart,
            )
        }
    }
}

// =============================================================
//  Step 2 — Refill (one machine focus)
// =============================================================

@Composable
private fun RefillStepContent(state: RefillUiState, viewModel: RefillWizardViewModel) {
    val current = state.currentMachine ?: run {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = BrandSlate900)
        }
        return
    }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = 16.dp,
                bottom = 140.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item { MachineFocusHeader(current, onFillAll = { viewModel.fillAllTraysToCapacity(current.machine.id) }) }
            items(current.trays, key = { it.tray.id }) { rt ->
                TrayRefillCard(
                    refillTray = rt,
                    onAdjust = { delta ->
                        viewModel.adjustFillAmount(
                            current.machine.id,
                            rt.tray.id,
                            rt.fillAmount + delta,
                        )
                    },
                )
            }
        }

        RefillStickyBar(
            onSkip = viewModel::skipCurrentMachine,
            onConfirm = viewModel::confirmCurrentMachine,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
private fun MachineFocusHeader(machine: RefillMachine, onFillAll: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = machine.machine.displayName,
                style = MaterialTheme.typography.titleLarge.copy(letterSpacing = (-0.3).sp),
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = "${machine.traysNeedingRefill} Fächer · ${machine.totalDeficit} Artikel",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(12.dp))
        LimeQuickAction(
            icon = Icons.Filled.Bolt,
            label = "Alle voll",
            onClick = onFillAll,
        )
    }
}

@Composable
private fun LimeQuickAction(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(BrandLime400)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = BrandSlate900, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Bold,
            color = BrandSlate900,
        )
    }
}

@Composable
private fun TrayRefillCard(refillTray: RefillTray, onAdjust: (Int) -> Unit) {
    val tray = refillTray.tray
    val targetRatio = ((tray.currentStock + refillTray.fillAmount).toFloat() / tray.capacity.coerceAtLeast(1))
        .coerceIn(0f, 1f)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Slot number as a tall badge
            Box(
                modifier = Modifier
                    .size(width = 44.dp, height = 52.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(BrandSlate900),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "${tray.itemNumber}",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BrandLime400,
                )
            }

            Spacer(Modifier.width(12.dp))

            ProductImage(tray.products?.imagePath, size = 44.dp)

            Spacer(Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = tray.productName,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                )
                Text(
                    text = "${tray.currentStock} → ${tray.currentStock + refillTray.fillAmount} / ${tray.capacity}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.width(8.dp))

            // Big amount badge — the focal point
            Text(
                text = "+${refillTray.fillAmount}",
                style = MaterialTheme.typography.displaySmall.copy(
                    fontSize = 32.sp,
                    letterSpacing = (-1).sp,
                ),
                fontWeight = FontWeight.Bold,
                color = if (refillTray.fillAmount > 0) BrandSlate900
                else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
            )
        }

        Spacer(Modifier.height(12.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            BigStepperButton(
                icon = Icons.Filled.Remove,
                enabled = refillTray.fillAmount > 0,
                onClick = { onAdjust(-1) },
            )
            Spacer(Modifier.width(8.dp))
            Box(
                modifier = Modifier.weight(1f),
            ) {
                MicroStockBar(ratio = targetRatio, onDarkBg = false)
            }
            Spacer(Modifier.width(8.dp))
            BigStepperButton(
                icon = Icons.Filled.Add,
                enabled = (tray.currentStock + refillTray.fillAmount) < tray.capacity,
                onClick = { onAdjust(+1) },
            )
        }
    }
}

@Composable
private fun BigStepperButton(icon: ImageVector, enabled: Boolean, onClick: () -> Unit) {
    val bg = if (enabled) BrandSlate900 else MaterialTheme.colorScheme.surfaceContainerHighest
    val fg = if (enabled) BrandLime400 else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = fg, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun RefillStickyBar(
    onSkip: () -> Unit,
    onConfirm: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .navigationBarsPadding(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        OutlineCtaButton(
            label = stringResource(R.string.refill_skip),
            onClick = onSkip,
            modifier = Modifier.weight(1f),
        )
        CtaButton(
            label = stringResource(R.string.refill_confirm),
            icon = Icons.Filled.Check,
            onClick = onConfirm,
            modifier = Modifier.weight(1.5f),
        )
    }
}

// =============================================================
//  Step 3 — Summary
// =============================================================

@Composable
private fun SummaryStep(state: RefillUiState, viewModel: RefillWizardViewModel) {
    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = 20.dp,
                bottom = 140.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { SummaryHero() }
            item { SummaryStatsRow(state) }
            item {
                Text(
                    text = "TOUR-LOG",
                    style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 2.sp),
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 4.dp, top = 8.dp),
                )
            }
            items(state.tourLog, key = { it.machineId }) { entry -> TourLogRow(entry) }
        }

        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surface)
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .navigationBarsPadding(),
        ) {
            CtaButton(
                label = stringResource(R.string.refill_finish),
                icon = Icons.Filled.Check,
                onClick = viewModel::reset,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun SummaryHero() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(BrandSlate900)
            .padding(24.dp),
    ) {
        Box(
            modifier = Modifier
                .size(64.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(BrandLime400),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = BrandSlate900,
                modifier = Modifier.size(36.dp),
            )
        }
        Spacer(Modifier.height(16.dp))
        Text(
            text = "Tour abgeschlossen",
            style = MaterialTheme.typography.headlineMedium.copy(letterSpacing = (-0.5).sp),
            fontWeight = FontWeight.Bold,
            color = Color.White,
        )
        Text(
            text = "Gut gemacht!",
            style = MaterialTheme.typography.bodyLarge,
            color = Color.White.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun SummaryStatsRow(state: RefillUiState) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SummaryStat(value = state.machinesVisited.toString(), label = "Maschinen", Modifier.weight(1f))
        SummaryStat(value = state.traysRefilled.toString(), label = "Fächer", Modifier.weight(1f))
        SummaryStat(value = "+${state.itemsAdded}", label = "Artikel", Modifier.weight(1f), accent = true)
    }
}

@Composable
private fun SummaryStat(value: String, label: String, modifier: Modifier = Modifier, accent: Boolean = false) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 14.dp, vertical = 16.dp),
    ) {
        Text(
            text = value,
            style = MaterialTheme.typography.headlineMedium.copy(letterSpacing = (-0.8).sp),
            fontWeight = FontWeight.Bold,
            color = if (accent) BrandSlate900 else MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 0.8.sp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun TourLogRow(entry: TourLogEntry) {
    val iconColor: Color = if (entry.skipped) MaterialTheme.colorScheme.onSurfaceVariant
    else VMGreen
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(iconColor.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (entry.skipped) Icons.Filled.Remove else Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = iconColor,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = entry.machineName,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            Text(
                text = if (entry.skipped) "Übersprungen"
                else "${entry.traysRefilled} Fächer · +${entry.totalAdded} Artikel",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// =============================================================
//  Reusable CTAs
// =============================================================

@Composable
private fun CtaButton(
    label: String,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bg = if (enabled) BrandSlate900 else BrandSlate900.copy(alpha = 0.38f)
    val fg = if (enabled) BrandLime400 else BrandLime400.copy(alpha = 0.5f)
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = 56.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(bg)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = fg,
        )
        if (icon != null) {
            Spacer(Modifier.width(10.dp))
            Icon(icon, null, tint = fg, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun OutlineCtaButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = 56.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

// =============================================================
//  Empty state — all machines stocked
// =============================================================

@Composable
private fun AllStockedState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(96.dp)
                .clip(RoundedCornerShape(28.dp))
                .background(BrandLime400.copy(alpha = 0.2f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = BrandSlate900,
                modifier = Modifier.size(48.dp),
            )
        }
        Spacer(Modifier.height(20.dp))
        Text(
            text = "Alle Maschinen voll",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = stringResource(R.string.refill_no_machines_need_refill),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
