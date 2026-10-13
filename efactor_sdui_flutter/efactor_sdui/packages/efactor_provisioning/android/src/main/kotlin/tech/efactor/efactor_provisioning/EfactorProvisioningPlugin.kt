package tech.efactor.efactor_provisioning

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import tech.efactor.proto.EfactorDiscoveryBridge
import tech.efactor.proto.EfactorProvisioningBridge
import tech.efactor.proto.EfactorDataBridge

/**
 * Android entry point for the eFactor plugin.
 *
 * Milestone 1: Cloud WebSocket. Wraps EfactorCloudManager and streams the four
 * callbacks (connected/message/disconnected/error) to Dart over an EventChannel.
 */
class EfactorProvisioningPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var logChannel: EventChannel
    private lateinit var cloudEventChannel: EventChannel
    private lateinit var discoveryEventChannel: EventChannel
    private lateinit var provisioningEventChannel: EventChannel

    private var cloudSink: EventChannel.EventSink? = null
    private var discoverySink: EventChannel.EventSink? = null
    private var provisioningSink: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private var cloud: EfactorCloudManager? = null
    private var discovery: EfactorDiscoveryBridge? = null
    private var provisioning: EfactorProvisioningBridge? = null
    private var data: EfactorDataBridge? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private companion object {
        const val TAG = "Plugin"
        const val LIB_VERSION = "v2.5.22"
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        android.util.Log.i("eFactor:Plugin", "efactor_provisioning v2.5.22 (build 2026-09-18)")

        methodChannel = MethodChannel(binding.binaryMessenger, "efactor_provisioning/methods")
        methodChannel.setMethodCallHandler(this)

        logChannel = EventChannel(binding.binaryMessenger, "efactor_provisioning/logs")
        logChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                EfNativeLog.attach(sink)
                EfNativeLog.i(TAG, "native log channel attached")
            }
            override fun onCancel(args: Any?) { EfNativeLog.attach(null) }
        })

        cloudEventChannel = EventChannel(binding.binaryMessenger, "efactor_provisioning/cloud_events")
        cloudEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                cloudSink = sink
                EfNativeLog.d(TAG, "cloud event channel listening")
            }
            override fun onCancel(args: Any?) { cloudSink = null }
        })

        discoveryEventChannel = EventChannel(binding.binaryMessenger, "efactor_provisioning/discovery_events")
        discoveryEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                discoverySink = sink
                EfNativeLog.d(TAG, "discovery event channel listening")
            }
            override fun onCancel(args: Any?) { discoverySink = null }
        })

        provisioningEventChannel = EventChannel(binding.binaryMessenger, "efactor_provisioning/provisioning_events")
        provisioningEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                provisioningSink = sink
                EfNativeLog.d(TAG, "provisioning event channel listening")
            }
            override fun onCancel(args: Any?) { provisioningSink = null }
        })

        EfNativeLog.i(TAG, "plugin attached (LIB_VERSION=${LIB_VERSION})")
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        logChannel.setStreamHandler(null)
        cloudEventChannel.setStreamHandler(null)
        discoveryEventChannel.setStreamHandler(null)
        provisioningEventChannel.setStreamHandler(null)
        discovery?.stop()
        provisioning?.cancel()
        EfNativeLog.i(TAG, "plugin detached")
    }

    /** Emits a cloud event to Dart: {type, message?}. Always on the main thread,
     *  because Java-WebSocket callbacks arrive on a background thread and Flutter
     *  channels must be used from the main thread only. */
    private fun emitCloud(type: String, message: String? = null) {
        mainHandler.post {
            EfNativeLog.d(TAG, "cloud event -> $type")
            cloudSink?.success(mapOf("type" to type, "message" to message))
        }
    }

    /** Bridges EfactorCloudManager callbacks to the Dart event stream. */
    private val bridgeCallback = object : EfactorCloudCallback {
        override fun onConnected() = emitCloud("connected")
        override fun onMessage(message: String) = emitCloud("message", message)
        override fun onDisconnected() = emitCloud("disconnected")
        override fun onError(e: Exception) = emitCloud("error", e.message ?: "error")
    }

    /** Emits a discovery event to Dart, on the main thread. */
    private fun emitDiscovery(map: Map<String, Any?>) {
        mainHandler.post { discoverySink?.success(map) }
    }

    /** Bridges mDNS discovery events to the Dart event stream. */
    private val discoveryListener = object : EfactorDiscoveryBridge.Listener {
        override fun onDeviceFound(nodeId: String, ip: String, port: Int) {
            EfNativeLog.d(TAG, "device found: $nodeId @ $ip:$port")
            emitDiscovery(mapOf(
                "type" to "found",
                "nodeId" to nodeId,
                "ip" to ip,
                "port" to port
            ))
        }
        override fun onDeviceLost(nodeId: String) {
            EfNativeLog.d(TAG, "device lost: $nodeId")
            emitDiscovery(mapOf("type" to "lost", "nodeId" to nodeId))
        }
    }

    /** Emits a provisioning event to Dart, on the main thread. */
    private fun emitProvisioning(map: Map<String, Any?>) {
        mainHandler.post { provisioningSink?.success(map) }
    }

    /** Bridges provisioning events to the Dart event stream. */
    private val provisioningListener = object : EfactorProvisioningBridge.Listener {
        override fun onProgress(stage: String, detail: String?) {
            EfNativeLog.d(TAG, "prov: $stage ${detail ?: ""}")
            emitProvisioning(mapOf("kind" to "progress", "stage" to stage, "detail" to detail))
        }
        override fun onResult(status: String, code: String?, detail: String?) {
            EfNativeLog.i(TAG, "prov result: $status ${code ?: ""} ${detail ?: ""}")
            emitProvisioning(mapOf(
                "kind" to "result",
                "status" to status,   // SUCCESS | APPLIED_UNCONFIRMED | FAILED
                "code" to code,       // AUTH_FAILED, NETWORK_NOT_FOUND, ... (FAILED only)
                "detail" to detail,
            ))
        }
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        EfNativeLog.d(TAG, "onMethodCall: ${call.method}")
        val ctx = appContext
        if (ctx == null) {
            result.error("NO_CONTEXT", "Plugin not attached", null)
            return
        }

        when (call.method) {
            "platformVersion" ->
                result.success("Android ${android.os.Build.VERSION.RELEASE}")

            "libVersion" -> result.success(LIB_VERSION)

            // ---- Cloud WebSocket ----
            "cloudInitialize" -> {
                val apiKey = call.argument<String>("apiKey")
                EfNativeLog.i(TAG, "cloudInitialize()")
                cloud = EfactorCloudManager.getInstance(ctx).also {
                    it.setCallback(apiKey, bridgeCallback)
                    it.initialize()
                }
                result.success(null)
            }

            "cloudGetDevices" -> withCloud(result) { c ->
                c.getDevices(reqFrom(call), bridgeCallback)
                result.success(null)
            }

            "cloudGetAllNodes" -> withCloud(result) { c ->
                c.getAllNodes(reqFrom(call), bridgeCallback)
                result.success(null)
            }

            "cloudGetAllNodesStatus" -> withCloud(result) { c ->
                c.getAllNodesStatus(reqFrom(call), bridgeCallback)
                result.success(null)
            }

            "cloudSetProvisionStarted" -> withCloud(result) { c ->
                c.setProvisionStarted(call.argument<Boolean>("status") ?: false)
                result.success(null)
            }

            "cloudReconnect" -> withCloud(result) { c ->
                c.reconnectToCloud()
                result.success(null)
            }

            "cloudDisconnect" -> withCloud(result) { c ->
                c.disconnect()
                result.success(null)
            }

            // ---- mDNS discovery ----
            "discoveryStart" -> {
                EfNativeLog.i(TAG, "discoveryStart()")
                val d = discovery ?: EfactorDiscoveryBridge(ctx).also { discovery = it }
                d.setListener(discoveryListener)
                d.start()
                result.success(null)
            }

            "discoveryStop" -> {
                EfNativeLog.i(TAG, "discoveryStop()")
                discovery?.stop()
                result.success(null)
            }

            "discoveryGetDevices" -> {
                result.success(discovery?.currentDevices() ?: emptyList<Map<String, Any?>>())
            }

            // ---- Provisioning (single-call auto chain) ----
            "provStart" -> {
                EfNativeLog.i(TAG, "provStart()")
                val p = provisioning ?: EfactorProvisioningBridge(ctx).also { provisioning = it }
                p.setListener(provisioningListener)
                p.startProvisioning(
                    call.argument<String>("pop") ?: "",
                    call.argument<String>("apiKey") ?: "",
                    call.argument<String>("ssid") ?: "",
                    call.argument<String>("password") ?: "",
                    call.argument<String>("userName") ?: "",     // <-- ADD THIS LINE
                    call.argument<String>("security") ?: "SEC1",
                )
                result.success(null)
            }

            "provCancel" -> withProv(result) { p ->
                p.cancel()
                result.success(null)
            }

            "sendData" -> {
                EfNativeLog.i(TAG, "sendData()")
                val bridge = data ?: EfactorDataBridge(ctx).also { data = it }
                bridge.sendData(
                    apiKey = call.argument<String>("apiKey") ?: "",
                    nodeId = call.argument<String>("nodeId") ?: "",
                    deviceId = call.argument<String>("deviceId") ?: "",
                    pageName = call.argument<String>("pageName") ?: "",
                    paramName = call.argument<String>("paramName") ?: "",
                    value = call.argument<Double>("value") ?: 0.0,
                    data = call.argument<String>("data") ?: "",
                    latitude = call.argument<String>("latitude") ?: "",
                    longitude = call.argument<String>("longitude") ?: "",
                    listener = object : EfactorDataBridge.ResultListener {
                        override fun onSuccess(raw: Map<String, Any?>) {
                            result.success(mapOf("ok" to true, "raw" to raw))
                        }
                        override fun onFailure(kind: String, raw: Map<String, Any?>) {
                            result.success(mapOf("ok" to false, "errorKind" to kind, "raw" to raw))
                        }
                    },
                )
            }

            else -> result.notImplemented()
        }
    }

    private inline fun withCloud(result: Result, block: (EfactorCloudManager) -> Unit) {
        val c = cloud
        if (c == null) {
            result.error("NOT_INITIALIZED", "Call cloudInitialize first", null)
            return
        }
        block(c)
    }

    private inline fun withProv(result: Result, block: (EfactorProvisioningBridge) -> Unit) {
        val p = provisioning
        if (p == null) {
            result.error("NOT_INITIALIZED", "Call provCreateDevice first", null)
            return
        }
        block(p)
    }

    private fun reqFrom(call: MethodCall): EfactorDeviceOperationRequest =
        EfactorDeviceOperationRequest(
            tokenKey = call.argument<String>("apiKey"),
            nodeId = call.argument<String>("nodeId"),
            deviceId = call.argument<String>("deviceId"),
        )
}
