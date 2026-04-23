package de.kerlhandel.vmflow.ui.common

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.kerlhandel.vmflow.data.model.StockHealth
import de.kerlhandel.vmflow.ui.theme.VMGreen
import de.kerlhandel.vmflow.ui.theme.VMRed
import de.kerlhandel.vmflow.ui.theme.VMYellow

@Composable
fun StockHealthIndicator(health: StockHealth, modifier: Modifier = Modifier) {
    val (icon, color, label) = when (health) {
        StockHealth.Ok -> Triple(Icons.Filled.CheckCircle, VMGreen, "Ok")
        StockHealth.Low -> Triple(Icons.Filled.Warning, VMYellow, "Low")
        StockHealth.Critical -> Triple(Icons.Filled.Error, VMRed, "Critical")
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(4.dp))
        Text(label, style = MaterialTheme.typography.labelMedium, color = color, fontWeight = FontWeight.Medium)
    }
}
