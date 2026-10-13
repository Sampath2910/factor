package com.example.efactor_sdui

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.MacAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.ScanResult
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android OS Wi-Fi capability bridge for the Flutter Wi-Fi SDUI.
 *
 * It contains no screen UI and no Efactor user/device credentials.
 * The Efactor provisioning protocol itself is handled by the
 * `efactor_provisioning` Flutter plugin.
 */
class WifiNativeBridge(
    private val activity: MainActivity,
) {
    companion object {
        private const val CHANNEL_NAME = "tech.efactor.studio/wifi_native"
        private const val TAG = "EfactorWifiNative"
        private const val SCAN_TIMEOUT_MS = 8_000L
        private const val SOFT_AP_CONNECT_TIMEOUT_MS = 90_000L
    }

    private val wifiManager =
        activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    private val connectivityManager =
        activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val handler = Handler(Looper.getMainLooper())

    private var boundNetwork: Network? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var connectTimeout: Runnable? = null
    private var scanReceiver: BroadcastReceiver? = null
    private var scanTimeout: Runnable? = null

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanRouterNetworks" -> {
                    try {
                        ensureScanPermission()
                        val excludePrefix =
                            call.argument<String>("excludeSsidPrefix")
                                ?.trim()
                                .orEmpty()
                        val minFrequency = call.argument<Int>("minFrequencyMHz")
                        val maxFrequency = call.argument<Int>("maxFrequencyMHz")

                        readFreshScanResults { results ->
                            try {
                                result.success(
                                    routerNetworks(
                                        results,
                                        excludePrefix,
                                        minFrequency,
                                        maxFrequency,
                                    ),
                                )
                            } catch (error: Throwable) {
                                result.error("WIFI_SCAN_FAILED", error.message, null)
                            }
                        }
                    } catch (error: Throwable) {
                        result.error("WIFI_SCAN_FAILED", error.message, null)
                    }
                }

                "scanDeviceSoftAp" -> {
                    try {
                        ensureScanPermission()
                        val expected =
                            call.argument<String>("expectedSsid")
                                ?.trim()
                                .orEmpty()
                        val prefix =
                            call.argument<String>("ssidPrefix")
                                ?.trim()
                                .orEmpty()
                        val minimumRssi = call.argument<Int>("minimumRssiDbm")

                        readFreshScanResults { results ->
                            try {
                                val matches =
                                    results
                                        .filter {
                                            it.SSID.isNotBlank() &&
                                                (
                                                    prefix.isEmpty() ||
                                                        it.SSID.startsWith(
                                                            prefix,
                                                            ignoreCase = true,
                                                        )
                                                )
                                        }
                                        .sortedByDescending { it.level }

                                val selected =
                                    if (expected.isNotEmpty()) {
                                        matches.firstOrNull {
                                            it.SSID.equals(expected, ignoreCase = true)
                                        }
                                    } else {
                                        when (matches.size) {
                                            0 -> null
                                            1 -> matches.first()
                                            else -> {
                                                result.error(
                                                    "MULTIPLE_EFACTOR_DEVICES",
                                                    "Multiple matching provisioning devices are nearby. " +
                                                        "Keep only the target device in provisioning mode " +
                                                        "or provide an exact device SoftAP SSID.",
                                                    null,
                                                )
                                                return@readFreshScanResults
                                            }
                                        }
                                    }

                                if (selected == null) {
                                    result.error(
                                        "EFACTOR_DEVICE_NOT_FOUND",
                                        if (expected.isEmpty()) {
                                            "No matching provisioning network was found."
                                        } else {
                                            "Expected Efactor SoftAP '$expected' was not found."
                                        },
                                        null,
                                    )
                                    return@readFreshScanResults
                                }

                                if (minimumRssi != null && selected.level < minimumRssi) {
                                    result.error(
                                        "DEVICE_SIGNAL_TOO_WEAK",
                                        "Device signal is ${selected.level} dBm. " +
                                            "Move the phone closer to the device.",
                                        null,
                                    )
                                    return@readFreshScanResults
                                }

                                Log.i(
                                    TAG,
                                    "Selected device SoftAP ssid=${selected.SSID} " +
                                        "bssid=${selected.BSSID} rssi=${selected.level}",
                                )
                                result.success(scanResultMap(selected))
                            } catch (error: Throwable) {
                                result.error("DEVICE_SCAN_FAILED", error.message, null)
                            }
                        }
                    } catch (error: Throwable) {
                        result.error("DEVICE_SCAN_FAILED", error.message, null)
                    }
                }

                "scanDeviceSoftApCandidates" -> {
                    try {
                        ensureScanPermission()
                        val prefix =
                            call.argument<String>("ssidPrefix")
                                ?.trim()
                                .orEmpty()
                        val minimumRssi = call.argument<Int>("minimumRssiDbm")

                        readFreshScanResults { results ->
                            try {
                                val matches =
                                    results
                                        .filter {
                                            it.SSID.isNotBlank() &&
                                                (
                                                    prefix.isEmpty() ||
                                                        it.SSID.startsWith(
                                                            prefix,
                                                            ignoreCase = true,
                                                        )
                                                ) &&
                                                (minimumRssi == null || it.level >= minimumRssi)
                                        }
                                        .sortedByDescending { it.level }
                                        .distinctBy { "${it.SSID.lowercase()}|${it.BSSID.lowercase()}" }
                                        .map(::scanResultMap)

                                result.success(matches)
                            } catch (error: Throwable) {
                                result.error(
                                    "DEVICE_SOFTAP_SCAN_FAILED",
                                    error.message ?: "Unable to scan provisioning devices.",
                                    null,
                                )
                            }
                        }
                    } catch (error: Throwable) {
                        result.error(
                            "DEVICE_SOFTAP_SCAN_FAILED",
                            error.message ?: "Unable to scan provisioning devices.",
                            null,
                        )
                    }
                }

                "connectDeviceSoftAp" -> {
                    val ssid = call.argument<String>("ssid")?.trim().orEmpty()
                    val bssid = call.argument<String>("bssid")?.trim().orEmpty()

                    if (ssid.isEmpty()) {
                        result.error(
                            "MISSING_DEVICE_SSID",
                            "Device SoftAP SSID is required.",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    connectOpenSoftAp(ssid, bssid, result)
                }

                "disconnectDeviceSoftAp" -> {
                    disconnectBoundNetwork()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        cancelPendingScan()
        disconnectBoundNetwork()
    }

    private fun ensureScanPermission() {
        val hasFine = ActivityCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val hasCoarse = ActivityCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val hasNearby = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.checkSelfPermission(
                activity, Manifest.permission.NEARBY_WIFI_DEVICES
            ) == PackageManager.PERMISSION_GRANTED
        } else true

        if (!hasFine && !hasCoarse && !hasNearby) {
            throw SecurityException("Required Android Wi-Fi / Location permission is missing.")
        }

        if (!wifiManager.isWifiEnabled) {
            throw IllegalStateException("Wi-Fi is disabled on the phone.")
        }
    }

    /**
     * Wait for Android's SCAN_RESULTS_AVAILABLE_ACTION instead of calling
     * startScan() and immediately consuming potentially stale cached results.
     *
     * Android may rate-limit startScan(); in that case we use the latest cached
     * results after a short delay rather than failing the schema flow.
     */
    @Suppress("DEPRECATION")
    private fun readFreshScanResults(
        completion: (List<ScanResult>) -> Unit,
    ) {
        cancelPendingScan()

        var finished = false

        fun finish() {
            if (finished) return
            finished = true
            cancelPendingScan()
            completion(wifiManager.scanResults ?: emptyList())
        }

        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == WifiManager.SCAN_RESULTS_AVAILABLE_ACTION) {
                        Log.d(TAG, "Fresh Wi-Fi scan results received")
                        finish()
                    }
                }
            }

        scanReceiver = receiver

        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(receiver, filter)
        }

        val timeout = Runnable {
            Log.w(TAG, "Wi-Fi scan timed out; using latest available results")
            finish()
        }
        scanTimeout = timeout
        handler.postDelayed(timeout, SCAN_TIMEOUT_MS)

        val started =
            try {
                wifiManager.startScan()
            } catch (_: Throwable) {
                false
            }

        if (!started) {
            Log.w(TAG, "Android rate-limited startScan(); using latest results")
            handler.postDelayed({ finish() }, 750L)
        }
    }

    private fun cancelPendingScan() {
        scanTimeout?.let(handler::removeCallbacks)
        scanTimeout = null

        val receiver = scanReceiver
        if (receiver != null) {
            try {
                activity.unregisterReceiver(receiver)
            } catch (_: Throwable) {
            }
        }
        scanReceiver = null
    }

    private fun routerNetworks(
        results: List<ScanResult>,
        excludePrefix: String,
        minFrequencyMHz: Int?,
        maxFrequencyMHz: Int?,
    ): List<Map<String, Any?>> {
        val unique = linkedMapOf<String, ScanResult>()

        results
            .asSequence()
            .filter {
                val prefixAllowed =
                    excludePrefix.isEmpty() ||
                        !it.SSID.startsWith(excludePrefix, ignoreCase = true)
                val minAllowed = minFrequencyMHz == null || it.frequency <= 0 || it.frequency >= minFrequencyMHz
                val maxAllowed = maxFrequencyMHz == null || it.frequency <= 0 || it.frequency <= maxFrequencyMHz

                it.SSID.isNotBlank() && prefixAllowed && minAllowed && maxAllowed
            }
            .sortedByDescending { it.level }
            .forEach {
                val old = unique[it.SSID]
                if (old == null || it.level > old.level) {
                    unique[it.SSID] = it
                }
            }

        // Ensure currently connected Wi-Fi is included if available
        try {
            val conn = wifiManager.connectionInfo
            val connSsid = conn?.ssid?.trim('"', ' ').orEmpty()
            if (connSsid.isNotEmpty() && connSsid != "<unknown ssid>" && !unique.containsKey(connSsid)) {
                if (excludePrefix.isEmpty() || !connSsid.startsWith(excludePrefix, ignoreCase = true)) {
                    val matching = results.firstOrNull { it.SSID == connSsid }
                    if (matching != null) {
                        unique[connSsid] = matching
                    }
                }
            }
        } catch (_: Throwable) {
        }

        return unique.values.map(::scanResultMap)
    }

    private fun scanResultMap(result: ScanResult): Map<String, Any?> {
        val security = securityLabel(result.capabilities)

        return mapOf(
            "ssid" to result.SSID,
            "bssid" to result.BSSID,
            "rssi" to result.level,
            "frequency" to result.frequency,
            "securityLabel" to security,
            "security" to security,
            "open" to security.equals("Open", ignoreCase = true),
        )
    }

    private fun securityLabel(capabilities: String?): String {
        val value = capabilities.orEmpty().uppercase()

        return when {
            value.contains("WPA3") || value.contains("SAE") -> "WPA3"
            value.contains("WPA2") -> "WPA2"
            value.contains("WPA") -> "WPA"
            value.contains("WEP") -> "WEP"
            else -> "Open"
        }
    }

    private fun connectOpenSoftAp(
        ssid: String,
        bssid: String,
        result: MethodChannel.Result,
    ) {
        disconnectBoundNetwork()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val builder =
                WifiNetworkSpecifier.Builder()
                    .setSsid(ssid)
                    .setIsHiddenSsid(false)

            if (bssid.isNotEmpty()) {
                try {
                    builder.setBssid(MacAddress.fromString(bssid))
                } catch (error: IllegalArgumentException) {
                    Log.w(TAG, "Ignoring invalid BSSID '$bssid': ${error.message}")
                }
            }

            val specifier = builder.build()

            val request =
                NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .setNetworkSpecifier(specifier)
                    .build()

            var completed = false

            lateinit var callback: ConnectivityManager.NetworkCallback

            fun fail(code: String, message: String) {
                if (completed) return
                completed = true
                cancelConnectTimeout()

                try {
                    connectivityManager.unregisterNetworkCallback(callback)
                } catch (_: Throwable) {
                }

                if (networkCallback === callback) networkCallback = null
                Log.w(TAG, "$code: $message")

                handler.post {
                    result.error(code, message, null)
                }
            }

            callback =
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        if (completed) return

                        val bound =
                            try {
                                connectivityManager.bindProcessToNetwork(network)
                            } catch (_: Throwable) {
                                false
                            }

                        if (!bound) {
                            fail(
                                "DEVICE_SOFTAP_BIND_FAILED",
                                "Android connected to '$ssid' but could not bind the app " +
                                    "to the device Wi-Fi network.",
                            )
                            return
                        }

                        completed = true
                        cancelConnectTimeout()
                        boundNetwork = network
                        networkCallback = callback
                        Log.i(TAG, "Connected and process-bound to device SoftAP '$ssid'")

                        handler.post {
                            result.success(
                                mapOf(
                                    "connected" to true,
                                    "ssid" to ssid,
                                    "bssid" to bssid,
                                ),
                            )
                        }
                    }

                    override fun onUnavailable() {
                        fail(
                            "DEVICE_SOFTAP_UNAVAILABLE",
                            "Android did not approve/connect to '$ssid'. " +
                                "When the system Wi-Fi connection dialog appears, tap Connect. " +
                                "Keep the device in provisioning mode and stay close to it.",
                        )
                    }

                    override fun onLost(network: Network) {
                        if (boundNetwork == network) {
                            Log.i(TAG, "Device SoftAP '$ssid' was lost")
                            try {
                                connectivityManager.bindProcessToNetwork(null)
                            } catch (_: Throwable) {
                            }
                            boundNetwork = null
                        }
                    }
                }

            networkCallback = callback

            val timeout = Runnable {
                fail(
                    "DEVICE_SOFTAP_APPROVAL_TIMEOUT",
                    "Timed out waiting for Android to connect to '$ssid'. " +
                        "Approve the system Wi-Fi connection request by tapping Connect.",
                )
            }
            connectTimeout = timeout
            handler.postDelayed(timeout, SOFT_AP_CONNECT_TIMEOUT_MS)

            Log.i(TAG, "Requesting Android connection to '$ssid' bssid='$bssid'")

            try {
                // Android 10+ intentionally shows a system approval dialog for
                // WifiNetworkSpecifier. The app cannot and must not bypass it.
                connectivityManager.requestNetwork(request, callback)
            } catch (error: Throwable) {
                fail(
                    "DEVICE_SOFTAP_CONNECT_FAILED",
                    error.message ?: "Android could not request the device Wi-Fi network.",
                )
            }
            return
        }

        @Suppress("DEPRECATION")
        val configuration =
            WifiConfiguration().apply {
                SSID = "\"$ssid\""
                allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            }

        @Suppress("DEPRECATION")
        val networkId = wifiManager.addNetwork(configuration)

        if (networkId < 0) {
            result.error(
                "DEVICE_SOFTAP_CONNECT_FAILED",
                "Android could not create a Wi-Fi configuration for '$ssid'.",
                null,
            )
            return
        }

        @Suppress("DEPRECATION")
        wifiManager.disconnect()

        @Suppress("DEPRECATION")
        val enabled = wifiManager.enableNetwork(networkId, true)

        @Suppress("DEPRECATION")
        wifiManager.reconnect()

        if (!enabled) {
            result.error(
                "DEVICE_SOFTAP_CONNECT_FAILED",
                "Android could not enable '$ssid'.",
                null,
            )
            return
        }

        handler.postDelayed(
            {
                result.success(
                    mapOf(
                        "connected" to true,
                        "ssid" to ssid,
                        "bssid" to bssid,
                    ),
                )
            },
            2_000,
        )
    }

    private fun cancelConnectTimeout() {
        connectTimeout?.let(handler::removeCallbacks)
        connectTimeout = null
    }

    private fun disconnectBoundNetwork() {
        cancelConnectTimeout()

        try {
            connectivityManager.bindProcessToNetwork(null)
        } catch (_: Throwable) {
        }

        val callback = networkCallback
        if (callback != null) {
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (_: Throwable) {
            }
        }

        networkCallback = null
        boundNetwork = null
    }
}
