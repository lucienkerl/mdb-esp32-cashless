package de.kerlhandel.vmflow.data.repository

import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import de.kerlhandel.vmflow.data.model.DealSearchResponse
import de.kerlhandel.vmflow.data.remote.SupabaseClientProvider
import de.kerlhandel.vmflow.di.IoDispatcher
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DealRepository @Inject constructor(
    private val clientProvider: SupabaseClientProvider,
    @IoDispatcher private val io: CoroutineDispatcher,
) {
    @Serializable
    data class DealSettings(
        @SerialName("deals_enabled") val dealsEnabled: Boolean? = null,
        @SerialName("deals_zip_code") val dealsZipCode: String? = null,
    )

    @Serializable
    private data class DealSearchBody(
        val forceRefresh: Boolean,
        val minConfidence: Double,
    )

    @Serializable
    private data class DealSettingsUpdate(
        @SerialName("deals_enabled") val dealsEnabled: Boolean,
        @SerialName("deals_zip_code") val dealsZipCode: String,
    )

    suspend fun fetchSettings(): DealSettings = withContext(io) {
        val rows = clientProvider.require().from("companies").select(
            Columns.raw("deals_enabled, deals_zip_code")
        ) { limit(1) }.decodeList<DealSettings>()
        rows.firstOrNull() ?: DealSettings()
    }

    suspend fun saveSettings(enabled: Boolean, zip: String) = withContext(io) {
        clientProvider.require().from("companies").update(
            DealSettingsUpdate(dealsEnabled = enabled, dealsZipCode = zip)
        ) {
            filter { neq("id", "00000000-0000-0000-0000-000000000000") }
        }
    }

    suspend fun searchDeals(forceRefresh: Boolean = false): DealSearchResponse = withContext(io) {
        val raw = clientProvider.require().functions.invoke("deal-search") {
            setBody(DealSearchBody(forceRefresh = forceRefresh, minConfidence = 0.5))
        }.bodyAsText()
        Json { ignoreUnknownKeys = true }.decodeFromString(DealSearchResponse.serializer(), raw)
    }
}
