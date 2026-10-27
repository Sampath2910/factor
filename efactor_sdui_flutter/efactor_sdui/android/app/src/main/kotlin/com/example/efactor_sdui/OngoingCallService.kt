package com.example.efactor_sdui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground Service that keeps WebRTC audio and video streaming active when
 * the app is minimized, screen is locked, or user switches to another app
 * during an active Circle Connect call.
 *
 * Provides the persistent "Ongoing call · tap to return" status bar notification.
 */
class OngoingCallService : Service() {

    companion object {
        const val TAG = "OngoingCallService"
        const val NOTIFICATION_ID = 88412
        const val CHANNEL_ID = "grid_ongoing_calls_v1"
        const val CHANNEL_NAME = "Active Calls"

        const val ACTION_START_CALL = "com.example.efactor_sdui.action.START_ONGOING_CALL"
        const val ACTION_STOP_CALL = "com.example.efactor_sdui.action.STOP_ONGOING_CALL"

        const val EXTRA_CALL_ID = "call_id"
        const val EXTRA_CALL_TYPE = "call_type"
        const val EXTRA_NAME = "name"
        const val EXTRA_IS_GROUP = "is_group"

        var isCallActive: Boolean = false
            private set
        var activeCallId: String? = null
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var callAudioModeActive = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: return START_NOT_STICKY

        when (action) {
            ACTION_START_CALL -> {
                val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: ""
                val callType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"
                val name = intent.getStringExtra(EXTRA_NAME) ?: ""
                val isGroup = intent.getBooleanExtra(EXTRA_IS_GROUP, false)

                startOngoingCallForeground(callId, callType, name, isGroup)
            }
            ACTION_STOP_CALL -> {
                stopOngoingCallForeground()
            }
        }

        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            val existing = notificationManager?.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Persistent notification for ongoing Circle Connect calls"
                    setShowBadge(false)
                    enableLights(false)
                    enableVibration(false)
                }
                notificationManager?.createNotificationChannel(channel)
            }
        }
    }

    private fun startOngoingCallForeground(
        callId: String,
        callType: String,
        name: String,
        isGroup: Boolean
    ) {
        Log.i(TAG, "Starting OngoingCallService for callId=$callId, type=$callType, name=$name, isGroup=$isGroup")
        isCallActive = true
        activeCallId = callId

        // Acquire partial WakeLock so CPU doesn't sleep during ongoing call audio/video streaming
        try {
            if (wakeLock == null) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = powerManager?.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "efactor:ongoing_call_wakelock"
                )?.apply {
                    setReferenceCounted(false)
                    acquire(2 * 60 * 60 * 1000L) // 2 hours max safety timeout
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed acquiring WakeLock: ${e.message}")
        }

        // Acquire WifiLock so Wi-Fi does not throttle when screen turns off
        try {
            if (wifiLock == null) {
                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wifiManager?.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "efactor:ongoing_call_wifilock"
                )?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed acquiring WifiLock: ${e.message}")
        }

        // Reuse the existing singleTop MainActivity and its WebView.
        // Do not add data that would reload the chat URL; a reload ends the call.
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra("route_to_call", true)
            putExtra("call_id", callId)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val isVideo = callType.equals("video", ignoreCase = true)
        val title = when {
            name.isNotBlank() -> name
            isGroup -> "Circle Connect Group Call"
            isVideo -> "Circle Connect Video Call"
            else -> "Circle Connect Voice Call"
        }
        val subtitle = if (isVideo) {
            "Ongoing video call · tap to return"
        } else {
            "Ongoing call · tap to return"
        }

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setSubText(if (isGroup) "Group Call" else (if (isVideo) "Video Call" else "Voice Call"))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .build()

        promoteToForeground(notification, isVideo)
        setCallAudioMode(inCall = true)
    }

    /**
     * Android 14+ throws SecurityException if type phoneCall is used without a
     * dialer role or a self-managed ConnectionService. Voice uses microphone.
     * Video adds camera. A failed video start falls back to microphone only.
     */
    private fun promoteToForeground(notification: Notification, isVideo: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification)
            Log.i(TAG, "Foreground service started without microphone type (API < 30)")
            return
        }

        val microphone = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (isVideo) {
            val microphoneAndCamera = microphone or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            try {
                startForeground(NOTIFICATION_ID, notification, microphoneAndCamera)
                Log.i(TAG, "Foreground service type=microphone|camera")
                return
            } catch (e: Exception) {
                Log.w(TAG, "microphone|camera rejected, falling back to microphone: ${e.message}")
            }
        }

        startForeground(NOTIFICATION_ID, notification, microphone)
        Log.i(TAG, "Foreground service type=microphone")
    }

    private fun setCallAudioMode(inCall: Boolean) {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            audioManager.mode = if (inCall) {
                AudioManager.MODE_IN_COMMUNICATION
            } else {
                AudioManager.MODE_NORMAL
            }
            callAudioModeActive = inCall
            Log.i(TAG, "AudioManager mode=${if (inCall) "MODE_IN_COMMUNICATION" else "MODE_NORMAL"}")
        } catch (e: Exception) {
            Log.w(TAG, "Audio mode change failed: ${e.message}")
        }
    }

    private fun stopOngoingCallForeground() {
        Log.i(TAG, "Stopping OngoingCallService for activeCallId=$activeCallId")
        isCallActive = false
        activeCallId = null

        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing wakeLock: ${e.message}")
        }

        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
            wifiLock = null
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing wifiLock: ${e.message}")
        }

        if (callAudioModeActive) {
            setCallAudioMode(inCall = false)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        stopOngoingCallForeground()
        super.onDestroy()
    }
}
