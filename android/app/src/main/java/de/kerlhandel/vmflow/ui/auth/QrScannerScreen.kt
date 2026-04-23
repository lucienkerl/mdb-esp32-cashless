package de.kerlhandel.vmflow.ui.auth

import android.Manifest
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import de.kerlhandel.vmflow.R
import de.kerlhandel.vmflow.data.model.ServerEntry
import de.kerlhandel.vmflow.ui.common.VMflowPrimaryButton
import de.kerlhandel.vmflow.ui.theme.BrandLime400
import de.kerlhandel.vmflow.ui.theme.BrandSlate800
import de.kerlhandel.vmflow.ui.theme.BrandSlate900
import kotlinx.serialization.json.Json
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Scans a QR code that carries server provisioning JSON of the form
 * `{"name": "…", "url": "…", "anonKey": "…"}` and hands the result to the
 * ServerViewModel. On successful scan we add + select the server and pop.
 */
@OptIn(ExperimentalPermissionsApi::class)
@Composable
fun QrScannerScreen(
    onBack: () -> Unit,
    viewModel: ServerViewModel = hiltViewModel(),
) {
    val permission = rememberPermissionState(Manifest.permission.CAMERA)
    LaunchedEffect(Unit) {
        if (!permission.status.isGranted) permission.launchPermissionRequest()
    }

    val scanned = remember { mutableStateOf(false) }
    val error = remember { mutableStateOf<String?>(null) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandSlate900),
    ) {
        if (permission.status.isGranted) {
            CameraPreview(
                onBarcode = { raw ->
                    if (scanned.value) return@CameraPreview
                    val entry = runCatching {
                        Json { ignoreUnknownKeys = true }
                            .decodeFromString(ServerEntryQr.serializer(), raw)
                    }.getOrNull()
                    if (entry != null) {
                        scanned.value = true
                        val server = ServerEntry(
                            id = UUID.randomUUID().toString(),
                            name = entry.name.ifBlank { "Scanned server" },
                            url = entry.url,
                            anonKey = entry.anonKey,
                        )
                        viewModel.save(server)
                        viewModel.select(server.id)
                        onBack()
                    } else {
                        error.value = "QR-Code enthält kein gültiges Server-JSON"
                    }
                },
            )
        } else {
            PermissionRequest(
                granted = permission.status.isGranted,
                onRequest = { permission.launchPermissionRequest() },
            )
        }

        ScanOverlay(Modifier.fillMaxSize())

        // Top bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(
                onClick = onBack,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(BrandSlate800),
            ) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.cd_close),
                    tint = Color.White,
                )
            }
            Spacer(Modifier.size(12.dp))
            Text(
                text = stringResource(R.string.auth_scan_qr),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
            )
        }

        error.value?.let { msg ->
            Text(
                text = msg,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 48.dp, start = 24.dp, end = 24.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.error.copy(alpha = 0.9f))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

@kotlinx.serialization.Serializable
private data class ServerEntryQr(
    val name: String = "",
    val url: String,
    val anonKey: String,
)

@Composable
private fun CameraPreview(onBarcode: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scanner: BarcodeScanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
    }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { analysisExecutor.shutdown() }
            runCatching { scanner.close() }
        }
    }

    AndroidView(
        factory = { ctx ->
            val previewView = PreviewView(ctx).apply {
                scaleType = PreviewView.ScaleType.FILL_CENTER
            }
            val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().apply {
                    surfaceProvider = previewView.surfaceProvider
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build().apply {
                        setAnalyzer(analysisExecutor) { imageProxy: ImageProxy ->
                            val media = imageProxy.image
                            if (media == null) {
                                imageProxy.close()
                                return@setAnalyzer
                            }
                            val input = InputImage.fromMediaImage(media, imageProxy.imageInfo.rotationDegrees)
                            scanner.process(input)
                                .addOnSuccessListener { barcodes ->
                                    barcodes.firstOrNull()?.rawValue?.let(onBarcode)
                                }
                                .addOnCompleteListener { imageProxy.close() }
                        }
                    }
                runCatching {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        },
        modifier = Modifier.fillMaxSize(),
    )
}

@Composable
private fun ScanOverlay(modifier: Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(260.dp)
                .clip(RoundedCornerShape(20.dp))
                .border(
                    width = 3.dp,
                    color = BrandLime400,
                    shape = RoundedCornerShape(20.dp),
                ),
        )
    }
}

@Composable
private fun PermissionRequest(granted: Boolean, onRequest: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                Icons.Filled.QrCodeScanner,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(72.dp),
            )
            Spacer(Modifier.size(16.dp))
            Text(
                text = "Kamera-Zugriff benötigt",
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.size(16.dp))
            VMflowPrimaryButton(
                text = "Berechtigung erteilen",
                onClick = onRequest,
            )
        }
    }
}
