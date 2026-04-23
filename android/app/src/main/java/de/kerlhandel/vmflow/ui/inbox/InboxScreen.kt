package de.kerlhandel.vmflow.ui.inbox

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.InboxItem
import de.kerlhandel.vmflow.data.repository.InboxRepository
import de.kerlhandel.vmflow.data.repository.NotificationRepository
import de.kerlhandel.vmflow.ui.common.VMflowTopAppBar
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class InboxViewModel @Inject constructor(
    private val inboxRepository: InboxRepository,
    private val notificationRepository: NotificationRepository,
) : ViewModel() {
    data class State(
        val loading: Boolean = false,
        val items: List<InboxItem> = emptyList(),
        val filter: InboxItem.Kind? = null,
        val onlyOpen: Boolean = true,
        val error: String? = null,
    ) {
        val visible: List<InboxItem>
            get() = items.filter { item ->
                (filter == null || item.kind == filter) && (!onlyOpen || item.isOpen)
            }
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    fun load() {
        _state.value = _state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            runCatching { inboxRepository.fetchInbox() }
                .onSuccess { _state.value = _state.value.copy(loading = false, items = it); notificationRepository.refreshBadge() }
                .onFailure { _state.value = _state.value.copy(loading = false, error = it.localizedMessage) }
        }
    }

    fun setFilter(kind: InboxItem.Kind?) { _state.value = _state.value.copy(filter = kind) }
    fun setOnlyOpen(b: Boolean) { _state.value = _state.value.copy(onlyOpen = b) }

    fun markReviewed(item: InboxItem) = update(item, InboxItem.Status.Reviewed)
    fun dismiss(item: InboxItem) = update(item, InboxItem.Status.Dismissed)
    fun delete(item: InboxItem) { viewModelScope.launch {
        runCatching { inboxRepository.delete(item) }.onSuccess { load() }
    } }

    private fun update(item: InboxItem, status: InboxItem.Status) = viewModelScope.launch {
        runCatching { inboxRepository.setStatus(item, status) }.onSuccess { load() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxScreen(viewModel: InboxViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(
        topBar = { VMflowTopAppBar(title = stringResource(R.string.nav_inbox)) },
        containerColor = MaterialTheme.colorScheme.background,
    ) { inner ->
        Column(Modifier.fillMaxSize().padding(inner)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilterChip(selected = state.filter == null, onClick = { viewModel.setFilter(null) }, label = { Text(stringResource(R.string.inbox_filter_all)) })
                FilterChip(selected = state.filter == InboxItem.Kind.Problem, onClick = { viewModel.setFilter(InboxItem.Kind.Problem) }, label = { Text(stringResource(R.string.inbox_filter_problem)) })
                FilterChip(selected = state.filter == InboxItem.Kind.Feedback, onClick = { viewModel.setFilter(InboxItem.Kind.Feedback) }, label = { Text(stringResource(R.string.inbox_filter_feedback)) })
                FilterChip(selected = state.filter == InboxItem.Kind.Wish, onClick = { viewModel.setFilter(InboxItem.Kind.Wish) }, label = { Text(stringResource(R.string.inbox_filter_wish)) })
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.inbox_show_open), style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(end = 8.dp))
                Switch(checked = state.onlyOpen, onCheckedChange = viewModel::setOnlyOpen)
            }

            if (state.loading && state.items.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = BrandSlate900) }
            } else if (state.visible.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.inbox_empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(state.visible, key = { it.source.table + it.id }) { item ->
                        InboxCard(item, viewModel::markReviewed, viewModel::dismiss, viewModel::delete)
                    }
                }
            }
        }
    }
}

@Composable
private fun InboxCard(
    item: InboxItem,
    onReview: (InboxItem) -> Unit,
    onDismiss: (InboxItem) -> Unit,
    onDelete: (InboxItem) -> Unit,
) {
    Card(
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    item.kind.raw.replaceFirstChar(Char::uppercase),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.size(8.dp))
                item.machineName?.let {
                    Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.size(8.dp))
                Text(item.status.raw, style = MaterialTheme.typography.labelSmall)
            }
            Spacer(Modifier.size(6.dp))
            Text(item.message, style = MaterialTheme.typography.bodyMedium)
            item.email?.let {
                Spacer(Modifier.size(4.dp))
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.size(6.dp))
            Row(horizontalArrangement = Arrangement.End) {
                IconButton(onClick = { onReview(item) }) { Icon(Icons.Filled.Check, contentDescription = stringResource(R.string.inbox_mark_reviewed)) }
                IconButton(onClick = { onDismiss(item) }) { Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.inbox_dismiss)) }
                IconButton(onClick = { onDelete(item) }) { Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.inbox_delete)) }
            }
        }
    }
}
