package de.kerlhandel.vmflow.data.repository

import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Count
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import de.kerlhandel.vmflow.data.model.InboxItem
import de.kerlhandel.vmflow.data.model.MachineFeedbackRow
import de.kerlhandel.vmflow.data.model.ProductWishRow
import de.kerlhandel.vmflow.data.model.toInboxItem
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class InboxRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    suspend fun fetchInbox(): List<InboxItem> = withContext(io) {
        coroutineScope {
            val client = clientProvider.require()
            val feedbackDeferred = async {
                client.from("machine_feedback").select(
                    Columns.raw("id, type, message, email, status, created_at, machine_id, vendingMachine(name)")
                ) {
                    order("created_at", Order.DESCENDING)
                    limit(200)
                }.decodeList<MachineFeedbackRow>()
            }
            val wishesDeferred = async {
                client.from("product_wishes").select(
                    Columns.raw("id, wish_text, email, status, created_at, machine_id, vendingMachine(name)")
                ) {
                    order("created_at", Order.DESCENDING)
                    limit(200)
                }.decodeList<ProductWishRow>()
            }
            val merged = feedbackDeferred.await().mapNotNull { it.toInboxItem() } +
                wishesDeferred.await().mapNotNull { it.toInboxItem() }
            merged.sortedByDescending { it.createdAt }
        }
    }

    suspend fun setStatus(item: InboxItem, status: InboxItem.Status) = withContext(io) {
        clientProvider.require().from(item.source.table).update(mapOf("status" to status.raw)) {
            filter { eq("id", item.id) }
        }
    }

    suspend fun delete(item: InboxItem) = withContext(io) {
        clientProvider.require().from(item.source.table).delete {
            filter { eq("id", item.id) }
        }
    }

    /** Counts open (status='new') entries in both tables. */
    suspend fun countOpen(): Int = withContext(io) {
        coroutineScope {
            val client = clientProvider.require()
            val fb = async {
                client.from("machine_feedback").select(Columns.raw("id")) {
                    filter { eq("status", "new") }
                    count(Count.EXACT)
                }
            }
            val wishes = async {
                client.from("product_wishes").select(Columns.raw("id")) {
                    filter { eq("status", "new") }
                    count(Count.EXACT)
                }
            }
            val fbCount = fb.await().countOrNull() ?: 0L
            val wishCount = wishes.await().countOrNull() ?: 0L
            (fbCount + wishCount).toInt()
        }
    }
}
