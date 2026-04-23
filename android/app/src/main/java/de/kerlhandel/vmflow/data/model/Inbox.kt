package de.kerlhandel.vmflow.data.model

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * One row of the operator inbox (customer-submitted from /m/[machine_id]).
 * Two source tables share this struct for a merged UI list:
 *  - `machine_feedback` (type = "problem" | "feedback")
 *  - `product_wishes`   (type = "wish")
 */
data class InboxItem(
    val id: String,
    val source: Source,
    val kind: Kind,
    val message: String,
    val email: String?,
    val status: Status,
    val createdAt: Instant,
    val machineId: String,
    val machineName: String?,
) {
    enum class Kind(val raw: String) {
        Problem("problem"), Feedback("feedback"), Wish("wish");
        companion object { fun parse(raw: String?) = entries.firstOrNull { it.raw == raw } }
    }
    enum class Status(val raw: String) {
        New("new"), Reviewed("reviewed"), Dismissed("dismissed");
        companion object { fun parse(raw: String?) = entries.firstOrNull { it.raw == raw } }
    }
    enum class Source(val table: String) {
        MachineFeedback("machine_feedback"), ProductWishes("product_wishes"),
    }

    val isOpen: Boolean get() = status == Status.New
}

@Serializable
data class MachineFeedbackRow(
    val id: String,
    val type: String,
    val message: String,
    val email: String? = null,
    val status: String,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("machine_id") val machineId: String,
    val vendingMachine: NestedMachine? = null,
) {
    @Serializable
    data class NestedMachine(val name: String? = null)
}

@Serializable
data class ProductWishRow(
    val id: String,
    @SerialName("wish_text") val wishText: String,
    val email: String? = null,
    val status: String,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("machine_id") val machineId: String,
    val vendingMachine: NestedMachine? = null,
) {
    @Serializable
    data class NestedMachine(val name: String? = null)
}

fun MachineFeedbackRow.toInboxItem(): InboxItem? {
    val kind = InboxItem.Kind.parse(type) ?: return null
    val status = InboxItem.Status.parse(status) ?: return null
    return InboxItem(
        id = id,
        source = InboxItem.Source.MachineFeedback,
        kind = kind,
        message = message,
        email = email,
        status = status,
        createdAt = createdAt,
        machineId = machineId,
        machineName = vendingMachine?.name,
    )
}

fun ProductWishRow.toInboxItem(): InboxItem? {
    val status = InboxItem.Status.parse(status) ?: return null
    return InboxItem(
        id = id,
        source = InboxItem.Source.ProductWishes,
        kind = InboxItem.Kind.Wish,
        message = wishText,
        email = email,
        status = status,
        createdAt = createdAt,
        machineId = machineId,
        machineName = vendingMachine?.name,
    )
}
