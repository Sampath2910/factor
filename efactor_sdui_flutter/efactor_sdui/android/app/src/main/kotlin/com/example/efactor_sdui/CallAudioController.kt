package com.example.efactor_sdui

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Owns OS audio focus and physical output routing for Circle Connect VoIP
 * calls (the WebView owns call UI/media state but cannot reliably move audio
 * between receiver, loudspeaker and Bluetooth).
 *
 * Driven from Dart over the `tech.efactor/circle_connect` channel; publishes
 * route snapshots back to Dart via `onAudioRoutesChanged`.
 */
class CallAudioController(
    private val context: Context,
    private val channel: MethodChannel,
) {
    companion object {
        private const val TAG = "CallAudioController"
    }

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var focusRequest: AudioFocusRequest? = null
    private var previousMode: Int = AudioManager.MODE_NORMAL
    private var active = false
    private var isVideo = false
    private var activeCallId: String? = null
    private var deviceCallback: AudioDeviceCallback? = null

    /**
     * Acquire transient VoIP focus (no ducking), set mode, apply default route.
     * Idempotent and keyed by [callId]: a repeat start for the active call only
     * re-applies routing (no second focus request).
     */
    fun startCallAudio(callId: String?, video: Boolean, preferredRoute: String?) {
        isVideo = video
        if (active && activeCallId == callId) {
            applyRoute(preferredRoute ?: defaultRouteType())
            publishRoutes()
            return
        }
        if (!active) {
            previousMode = audioManager.mode
            requestFocus()
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            registerDeviceCallback()
            active = true
        }
        activeCallId = callId
        applyRoute(preferredRoute ?: defaultRouteType())
        publishRoutes()
    }

    /** Report routes only; must never acquire focus (may arrive before start). */
    fun getCallAudioRoutes() = publishRoutes()

    fun setCallAudioRoute(routeId: String?, routeType: String?) {
        applyRoute(routeType ?: routeId ?: defaultRouteType(), explicitId = routeId)
        publishRoutes()
    }

    /** Update metadata/default routing only; never restarts focus. */
    fun callMediaTypeChanged(callId: String?, video: Boolean) {
        isVideo = video
        publishRoutes()
    }

    /**
     * Clear device, restore mode, abandon the exact focus request, unregister.
     * Ignores an End whose [callId] is not the active call (stale/out-of-order).
     */
    fun endCallAudio(callId: String?) {
        if (!active || (callId != null && callId != activeCallId)) return
        active = false
        activeCallId = null
        unregisterDeviceCallback()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                if (audioManager.isBluetoothScoOn) {
                    audioManager.stopBluetoothSco()
                    audioManager.isBluetoothScoOn = false
                }
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "clear device failed: ${e.message}")
        }
        audioManager.mode = previousMode
        abandonFocus()
    }

    // --- focus ---

    private fun requestFocus() {
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // AUDIOFOCUS_GAIN_TRANSIENT, no willPauseWhenDucked -> other
                // media is paused (not ducked), per contract.
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attrs)
                    .build()
                focusRequest = req
                audioManager.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    null,
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "requestFocus failed: ${e.message}")
        }
    }

    private fun abandonFocus() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(null)
            }
        } catch (e: Exception) {
            Log.w(TAG, "abandonFocus failed: ${e.message}")
        }
    }

    // --- routing ---

    private fun defaultRouteType(): String {
        // Voice: BT/wired if connected, else receiver. Video: BT/wired else speaker.
        connectedHeadsetType()?.let { return it }
        return if (isVideo) "speaker" else "phone"
    }

    private fun connectedHeadsetType(): String? {
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        for (d in devices) {
            when (routeType(d.type)) {
                "bluetooth" -> return "bluetooth"
                "wired" -> return "wired"
            }
        }
        return null
    }

    private fun applyRoute(routeType: String, explicitId: String? = null) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val target = pickCommunicationDevice(routeType, explicitId)
                if (target != null) {
                    audioManager.setCommunicationDevice(target)
                } else {
                    // Requested device gone: fall back per call type.
                    val fb = pickCommunicationDevice(
                        if (isVideo) "speaker" else "phone", null,
                    )
                    if (fb != null) audioManager.setCommunicationDevice(fb)
                }
            } else {
                applyRouteLegacy(routeType)
            }
        } catch (e: Exception) {
            Log.w(TAG, "applyRoute($routeType) failed: ${e.message}")
        }
    }

    @Suppress("DEPRECATION")
    private fun applyRouteLegacy(routeType: String) {
        when (routeType) {
            "bluetooth" -> {
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
                audioManager.isSpeakerphoneOn = false
            }
            "speaker" -> {
                if (audioManager.isBluetoothScoOn) {
                    audioManager.stopBluetoothSco()
                    audioManager.isBluetoothScoOn = false
                }
                audioManager.isSpeakerphoneOn = true
            }
            else -> { // phone / wired
                if (audioManager.isBluetoothScoOn) {
                    audioManager.stopBluetoothSco()
                    audioManager.isBluetoothScoOn = false
                }
                audioManager.isSpeakerphoneOn = false
            }
        }
    }

    private fun pickCommunicationDevice(
        routeType: String,
        explicitId: String?,
    ): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val devices = audioManager.availableCommunicationDevices
        if (explicitId != null) {
            devices.firstOrNull { it.id.toString() == explicitId }?.let { return it }
        }
        return devices.firstOrNull { routeType(it.type) == routeType }
    }

    // --- snapshot publishing ---

    private fun registerDeviceCallback() {
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) =
                publishRoutes()

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) =
                publishRoutes()
        }
        deviceCallback = cb
        audioManager.registerAudioDeviceCallback(cb, mainHandler)
    }

    private fun unregisterDeviceCallback() {
        deviceCallback?.let { audioManager.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
    }

    private fun publishRoutes() {
        val routes = ArrayList<Map<String, String>>()
        val selected: String?
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audioManager.availableCommunicationDevices
            val seen = HashSet<String>()
            for (d in devices) {
                val type = routeType(d.type)
                if (!seen.add(type + ":" + d.id)) continue
                routes.add(route(d.id.toString(), type, label(d)))
            }
            selected = audioManager.communicationDevice?.id?.toString()
        } else {
            routes.add(route("phone", "phone", "Phone"))
            routes.add(route("speaker", "speaker", "Speaker"))
            connectedHeadsetType()?.let { routes.add(route(it, it, headsetLabel(it))) }
            @Suppress("DEPRECATION")
            selected = when {
                audioManager.isBluetoothScoOn -> "bluetooth"
                audioManager.isSpeakerphoneOn -> "speaker"
                else -> "phone"
            }
        }
        val snapshot = mapOf("selectedRouteId" to selected, "routes" to routes)
        mainHandler.post {
            try {
                channel.invokeMethod("onAudioRoutesChanged", snapshot)
            } catch (e: Exception) {
                Log.w(TAG, "publishRoutes invoke failed: ${e.message}")
            }
        }
    }

    private fun route(id: String, type: String, label: String) =
        mapOf("id" to id, "type" to type, "label" to label)

    private fun label(d: AudioDeviceInfo): String {
        val name = d.productName?.toString()?.trim()
        if (!name.isNullOrEmpty()) return name
        return headsetLabel(routeType(d.type))
    }

    private fun headsetLabel(type: String): String = when (type) {
        "bluetooth" -> "Bluetooth"
        "wired" -> "Wired headset"
        "speaker" -> "Speaker"
        "phone" -> "Phone"
        else -> "Output"
    }

    private fun routeType(deviceType: Int): String = when (deviceType) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE -> "wired"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "phone"
        else -> "output"
    }
}
