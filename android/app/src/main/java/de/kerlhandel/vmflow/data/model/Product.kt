package de.kerlhandel.vmflow.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Product(
    val id: String,
    val name: String? = null,
    @SerialName("image_path") val imagePath: String? = null,
    val discontinued: Boolean? = null,
    val sellprice: Double? = null,
    val category: String? = null,
)

@Serializable
data class ProductCategory(
    val id: String,
    val name: String,
    val company: String,
)

@Serializable
data class ProductBarcode(
    val id: String,
    @SerialName("product_id") val productId: String,
    val barcode: String,
    val format: String,
    @SerialName("company_id") val companyId: String,
)

/** Lightweight product info from a tray query's `products(...)` relation. */
@Serializable
data class TrayProduct(
    val name: String? = null,
    @SerialName("image_path") val imagePath: String? = null,
    val discontinued: Boolean? = null,
    val sellprice: Double? = null,
)
