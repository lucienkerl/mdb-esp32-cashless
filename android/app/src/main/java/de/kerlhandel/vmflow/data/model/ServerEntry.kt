package de.kerlhandel.vmflow.data.model

import kotlinx.serialization.Serializable

@Serializable
data class ServerEntry(
    val id: String,
    val name: String,
    val url: String,
    val anonKey: String,
    val isDefault: Boolean = false,
) {
    val sanitizedUrl: String get() = url.trimEnd('/')

    val isValid: Boolean
        get() {
            if (name.isBlank() || url.isBlank() || anonKey.isBlank()) return false
            val scheme = sanitizedUrl.substringBefore("://", missingDelimiterValue = "")
                .lowercase()
            if (scheme != "http" && scheme != "https") return false
            val host = sanitizedUrl.substringAfter("://").substringBefore("/")
            return host.isNotBlank()
        }
}
