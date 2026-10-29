<script setup lang="ts">
import type { PendingPurchasePrice } from '~/composables/usePurchasePrices'

const props = defineProps<{
  open: boolean
  productId?: string | null
}>()

const emit = defineEmits<{
  'update:open': [value: boolean]
  'saved': [productId: string]
}>()

const { t } = useI18n()
const { organization, role } = useOrganization()
const { products, categories, createProduct, updateProduct, uploadProductImage, deleteProductImage } = useProducts()
const { barcodes: allBarcodes, addBarcode, removeBarcode } = useWarehouse()
const { images: suggestedImages, searching: searchingImages, loadingMore: loadingMoreImages, hasMore: hasMoreImages, foodOnly, searchDebounced, loadMore: loadMoreImages, downloadImage: downloadSuggestedImage, clear: clearImageSearch } = useProductImageSearch()
const { addPurchasePrice } = usePurchasePrices()

const isAdmin = computed(() => role.value === 'admin')

// Resolve the editing product from the productId prop
const editingProduct = computed<any | null>(() => {
  if (!props.productId) return null
  return products.value.find((p: any) => p.id === props.productId) ?? null
})

// ── Product form state ────────────────────────────────────────────────────
const productForm = ref({ name: '', sellprice: null as number | null, description: '', category: '', discontinued: false })
// Purchase prices buffered during NEW-product creation (flushed after createProduct).
const pendingPurchasePrices = ref<PendingPurchasePrice[]>([])
const productLoading = ref(false)
const productError = ref('')

// Image upload state
const imageFile = ref<File | null>(null)
const imagePreview = ref<string | null>(null)
const removeImage = ref(false)
const selectedImageUrl = ref<string | null>(null) // full-size URL from suggestion

// ── Barcode management ────────────────────────────────────────────────────
const productBarcodes = computed(() => {
  if (!editingProduct.value) return []
  return allBarcodes.value.filter((b: any) => b.product_id === editingProduct.value.id)
})
const newBarcodeInput = ref('')
const barcodeAddError = ref('')
const showProductScanner = ref(false)
// Pending barcodes for new product creation (not yet saved to DB)
const pendingBarcodes = ref<string[]>([])

function onProductBarcodeDetected(barcode: string) {
  showProductScanner.value = false
  if (editingProduct.value) {
    // Editing existing product — save directly
    newBarcodeInput.value = barcode
    addProductBarcode()
  } else {
    // Creating new product — queue for later
    if (!pendingBarcodes.value.includes(barcode)) {
      pendingBarcodes.value.push(barcode)
    }
  }
}

function addPendingBarcode() {
  const val = newBarcodeInput.value.trim()
  if (!val) return
  if (!pendingBarcodes.value.includes(val)) {
    pendingBarcodes.value.push(val)
  }
  newBarcodeInput.value = ''
}

function removePendingBarcode(barcode: string) {
  pendingBarcodes.value = pendingBarcodes.value.filter(b => b !== barcode)
}

async function addProductBarcode() {
  if (!newBarcodeInput.value.trim() || !editingProduct.value) return
  barcodeAddError.value = ''
  try {
    await addBarcode({ product_id: editingProduct.value.id, barcode: newBarcodeInput.value.trim() })
    newBarcodeInput.value = ''
  } catch (err: any) {
    barcodeAddError.value = err.message ?? t('common.failedTo', { action: 'add barcode' })
  }
}

async function removeProductBarcode(id: string) {
  await removeBarcode(id)
}

// Watch product name for image suggestions (when no image is set)
watch(() => productForm.value.name, (name) => {
  if (!imageFile.value && !selectedImageUrl.value && !imagePreview.value) {
    searchDebounced(name)
  }
})

// The suggestions block (and with it the food-filter checkbox) stays up while
// the product has no image and the name is long enough for a lookup, even if
// the current filter returns nothing.
const imageSearchVisible = computed(() =>
  !imagePreview.value
  && (searchingImages.value
    || suggestedImages.value.length > 0
    || (productForm.value.name?.trim().length ?? 0) >= 2),
)

function selectSuggestedImage(thumbnail: string, imageUrl: string) {
  imagePreview.value = thumbnail
  selectedImageUrl.value = imageUrl
  imageFile.value = null
  clearImageSearch()
}

function onImageSelected(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  imageFile.value = file
  removeImage.value = false
  const reader = new FileReader()
  reader.onload = (e) => {
    imagePreview.value = e.target?.result as string
  }
  reader.readAsDataURL(file)
}

function clearImage() {
  imageFile.value = null
  imagePreview.value = null
  selectedImageUrl.value = null
  if (editingProduct.value?.image_path) {
    removeImage.value = true
  }
}

// Reset form state when modal opens or productId changes — initialise from editingProduct in edit mode
watch([() => props.open, () => props.productId], ([open]) => {
  if (!open) return
  pendingPurchasePrices.value = []
  const prod = editingProduct.value
  if (prod) {
    productForm.value = {
      name: prod.name ?? '',
      sellprice: prod.sellprice,
      description: prod.description ?? '',
      category: prod.category ?? '',
      discontinued: prod.discontinued ?? false,
    }
    imageFile.value = null
    imagePreview.value = prod.image_url ?? null
    removeImage.value = false
    selectedImageUrl.value = null
    clearImageSearch()
    productError.value = ''
    newBarcodeInput.value = ''
    barcodeAddError.value = ''
    pendingBarcodes.value = []
    // Trigger image search if product has no image
    if (!prod.image_url && prod.name) {
      searchDebounced(prod.name)
    }
  } else {
    productForm.value = { name: '', sellprice: null, description: '', category: '', discontinued: false }
    imageFile.value = null
    imagePreview.value = null
    removeImage.value = false
    selectedImageUrl.value = null
    clearImageSearch()
    productError.value = ''
    pendingBarcodes.value = []
    newBarcodeInput.value = ''
    barcodeAddError.value = ''
  }
})

async function submitProduct() {
  if (!productForm.value.name.trim()) {
    productError.value = t('products.nameRequired')
    return
  }
  productLoading.value = true
  productError.value = ''
  try {
    let productId: string
    if (editingProduct.value) {
      productId = editingProduct.value.id
      await updateProduct(productId, {
        name: productForm.value.name.trim(),
        sellprice: productForm.value.sellprice,
        description: productForm.value.description.trim() || null,
        category: productForm.value.category || null,
        discontinued: productForm.value.discontinued,
      })
    } else {
      productId = await createProduct({
        name: productForm.value.name.trim(),
        sellprice: productForm.value.sellprice,
        description: productForm.value.description.trim() || null,
        category: productForm.value.category || null,
        company: organization.value!.id,
        discontinued: productForm.value.discontinued,
      })
    }

    // Handle image changes
    if (removeImage.value && editingProduct.value?.image_path) {
      await deleteProductImage(productId, editingProduct.value.image_path)
    }
    // Download suggested image if selected
    if (selectedImageUrl.value && !imageFile.value) {
      const file = await downloadSuggestedImage(selectedImageUrl.value)
      if (file) imageFile.value = file
    }
    if (imageFile.value) {
      await uploadProductImage(productId, imageFile.value)
    }

    // Save pending barcodes (new product creation)
    if (!editingProduct.value && pendingBarcodes.value.length > 0) {
      for (const barcode of pendingBarcodes.value) {
        try {
          await addBarcode({ product_id: productId, barcode })
        } catch {
          // ignore duplicates or failures for individual barcodes
        }
      }
      pendingBarcodes.value = []
    }

    // Save pending purchase prices (new product creation). Net/gross + tax rate
    // resolve server-side now that the product (and its category) exist.
    if (!editingProduct.value && pendingPurchasePrices.value.length > 0) {
      for (const e of pendingPurchasePrices.value) {
        try {
          await addPurchasePrice({
            productId,
            supplierName: e.supplierName,
            price: e.price,
            basis: e.basis,
            observedOn: e.observedOn,
            note: e.note,
          })
        } catch {
          // Product is saved; an individual EK may fail (e.g. a category without a
          // tax rate). The user can add it in edit mode where the % fallback exists.
        }
      }
      pendingPurchasePrices.value = []
    }

    emit('saved', productId)
    emit('update:open', false)
  } catch (err: unknown) {
    productError.value = err instanceof Error ? err.message : t('products.failedToSave')
  } finally {
    productLoading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="editingProduct ? t('products.editProduct') : t('products.addProduct')"
    size="sm"
    @update:open="emit('update:open', $event)"
  >
    <form class="space-y-4" @submit.prevent="submitProduct">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="product-name">{{ t('common.name') }}</label>
        <input
          id="product-name"
          v-model="productForm.name"
          type="text"
          required
          :placeholder="t('products.productName')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <!-- Image upload -->
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('products.image') }}</label>
        <div v-if="imagePreview" class="relative inline-block">
          <img :src="imagePreview" :alt="t('common.preview')" class="h-24 w-24 rounded-lg object-cover border" />
          <button
            type="button"
            class="absolute -right-2 -top-2 flex h-5 w-5 items-center justify-center rounded-full bg-destructive text-destructive-foreground text-xs shadow"
            @click="clearImage"
          >
            &times;
          </button>
        </div>
        <div v-else>
          <label
            for="product-image"
            class="flex h-24 w-full cursor-pointer items-center justify-center rounded-lg border-2 border-dashed border-muted-foreground/25 text-sm text-muted-foreground transition-colors hover:border-muted-foreground/50 hover:bg-muted/30"
          >
            <div class="text-center">
              <svg xmlns="http://www.w3.org/2000/svg" class="mx-auto mb-1 h-6 w-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/></svg>
              <span>{{ t('products.clickToUpload') }}</span>
            </div>
          </label>
          <input
            id="product-image"
            type="file"
            accept="image/png,image/jpeg,image/webp"
            class="hidden"
            @change="onImageSelected"
          />
        </div>
        <!-- Image suggestions -->
        <!-- Stays up even on an empty result set, otherwise a too-narrow filter
             would hide its own off switch. -->
        <div v-if="imageSearchVisible" class="mt-2">
          <label class="mb-1.5 flex items-start gap-2 text-xs text-muted-foreground">
            <input v-model="foodOnly" type="checkbox" class="mt-0.5 size-3.5 shrink-0 accent-primary" />
            <span>
              <span class="font-medium text-foreground">{{ t('products.foodOnlyImages') }}</span>
              — {{ t('products.foodOnlyImagesHint') }}
            </span>
          </label>
          <p v-if="searchingImages || suggestedImages.length > 0" class="mb-1.5 text-xs text-muted-foreground">{{ searchingImages ? t('products.searchingImages') : t('products.imageSuggestions') }}</p>
          <div v-if="searchingImages" class="flex items-center gap-2 text-xs text-muted-foreground">
            <svg class="size-4 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg>
          </div>
          <template v-else>
            <div class="grid grid-cols-4 gap-1.5">
              <button
                v-for="img in suggestedImages"
                :key="img.image"
                type="button"
                class="group relative aspect-square overflow-hidden rounded-md border hover:ring-2 hover:ring-primary"
                :title="img.title"
                @click="selectSuggestedImage(img.thumbnail, img.image)"
              >
                <img :src="img.thumbnail" :alt="img.title" class="h-full w-full object-cover" loading="lazy" />
              </button>
            </div>
            <button
              v-if="hasMoreImages || loadingMoreImages"
              type="button"
              :disabled="loadingMoreImages"
              class="mt-1.5 inline-flex h-8 w-full items-center justify-center gap-2 rounded-md border text-xs font-medium hover:bg-muted disabled:opacity-50"
              @click="loadMoreImages"
            >
              <svg v-if="loadingMoreImages" class="size-3.5 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg>
              {{ loadingMoreImages ? t('common.loading') : t('products.showMoreImages') }}
            </button>
          </template>
        </div>
      </div>

      <div class="space-y-1">
        <label class="text-sm font-medium" for="product-price">{{ t('products.price') }}</label>
        <input
          id="product-price"
          v-model.number="productForm.sellprice"
          type="number"
          step="0.01"
          min="0"
          :placeholder="t('products.pricePlaceholder')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="product-category">{{ t('products.category') }}</label>
        <select
          id="product-category"
          v-model="productForm.category"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option value="">—</option>
          <option v-for="cat in categories" :key="cat.id" :value="cat.id">{{ cat.name }}</option>
        </select>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="product-description">{{ t('common.description') }}</label>
        <textarea
          id="product-description"
          v-model="productForm.description"
          rows="3"
          :placeholder="t('products.optionalDescription')"
          class="flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="flex items-center gap-2">
        <input
          id="product-discontinued"
          v-model="productForm.discontinued"
          type="checkbox"
          class="size-4 rounded border-input accent-primary"
        />
        <label class="cursor-pointer select-none text-sm font-medium" for="product-discontinued">
          {{ t('products.discontinued') }}
        </label>
      </div>
      <!-- Barcodes -->
      <div v-if="isAdmin" class="space-y-2">
        <label class="text-sm font-medium">{{ t('products.barcodes') }}</label>
        <!-- Existing barcodes (edit mode) -->
        <div v-if="editingProduct && productBarcodes.length > 0" class="flex flex-wrap gap-1.5">
          <span
            v-for="b in productBarcodes"
            :key="b.id"
            class="inline-flex items-center gap-1 rounded-full border bg-muted/50 py-0.5 pl-2.5 pr-1 text-xs font-mono"
          >
            {{ b.barcode }}
            <button
              type="button"
              class="ml-0.5 flex size-4 items-center justify-center rounded-full text-muted-foreground hover:bg-destructive hover:text-destructive-foreground"
              @click="removeProductBarcode(b.id)"
            >
              &times;
            </button>
          </span>
        </div>
        <!-- Pending barcodes (add mode) -->
        <div v-if="!editingProduct && pendingBarcodes.length > 0" class="flex flex-wrap gap-1.5">
          <span
            v-for="bc in pendingBarcodes"
            :key="bc"
            class="inline-flex items-center gap-1 rounded-full border bg-muted/50 py-0.5 pl-2.5 pr-1 text-xs font-mono"
          >
            {{ bc }}
            <button
              type="button"
              class="ml-0.5 flex size-4 items-center justify-center rounded-full text-muted-foreground hover:bg-destructive hover:text-destructive-foreground"
              @click="removePendingBarcode(bc)"
            >
              &times;
            </button>
          </span>
        </div>
        <div class="flex gap-1.5">
          <input
            v-model="newBarcodeInput"
            type="text"
            :placeholder="t('products.barcodePlaceholder')"
            class="flex h-8 flex-1 rounded-md border border-input bg-background px-2 text-xs font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            @keydown.enter.prevent="editingProduct ? addProductBarcode() : addPendingBarcode()"
          />
          <button
            type="button"
            class="h-8 rounded-md border px-2 text-xs font-medium hover:bg-muted"
            @click="editingProduct ? addProductBarcode() : addPendingBarcode()"
          >
            {{ t('common.add') }}
          </button>
          <button
            type="button"
            class="flex h-8 items-center gap-1 rounded-md border px-2 text-xs font-medium hover:bg-muted"
            @click="showProductScanner = true"
          >
            <svg xmlns="http://www.w3.org/2000/svg" class="size-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/><line x1="7" x2="17" y1="12" y2="12"/><line x1="7" x2="17" y1="8" y2="8"/><line x1="7" x2="17" y1="16" y2="16"/></svg>
            {{ t('warehouse.scanBarcode') }}
          </button>
        </div>
        <p v-if="barcodeAddError" class="text-xs text-destructive">{{ barcodeAddError }}</p>
      </div>
      <!-- Purchase prices (edit mode, admin only) -->
      <!-- Purchase prices (admin). Edit mode persists immediately; create mode
           buffers and the parent flushes after the product is created. -->
      <PurchasePricesSection
        v-if="isAdmin"
        :product-id="editingProduct?.id ?? null"
        :sellprice="productForm.sellprice"
        v-model:pending="pendingPurchasePrices"
      />
      <!-- Barcode Scanner overlay -->
      <BarcodeScanner
        v-if="showProductScanner"
        @detected="(barcode: string) => onProductBarcodeDetected(barcode)"
        @close="showProductScanner = false"
      />

      <FormError :message="productError" />
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="emit('update:open', false)"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="productLoading"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="productLoading">{{ t('common.saving') }}</span>
          <span v-else>{{ editingProduct ? t('common.save') : t('common.create') }}</span>
        </button>
      </div>
    </form>
  </AppModal>
</template>
