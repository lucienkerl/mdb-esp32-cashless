package de.kerlhandel.vmflow.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Organization(
    val id: String,
    val name: String,
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class OrganizationResponse(
    val organization: Organization? = null,
    val role: String? = null,
)

enum class OrganizationRole { Admin, Viewer;
    companion object {
        fun parse(raw: String?): OrganizationRole? = when (raw?.lowercase()) {
            "admin" -> Admin
            "viewer" -> Viewer
            else -> null
        }
    }
}
