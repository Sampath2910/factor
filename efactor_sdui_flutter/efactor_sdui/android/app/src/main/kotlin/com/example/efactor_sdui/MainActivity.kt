package com.example.efactor_sdui

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebView
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Application host.
 *
 * Efactor Cloud / Provision / Discovery / Data are registered automatically by
 * the local `efactor_provisioning` Flutter plugin.
 *
 * This activity registers Android OS Wi-Fi capabilities and Circle Connect /
 * Professional Space WebKit cookie synchronization.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_CODE_RINGTONE_PICKER = 9921
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_CALLS_CHANNEL_ID = "flutter.circle_connect_calls_channel_id"
        private const val PREF_MESSAGES_CHANNEL_ID = "flutter.circle_connect_messages_channel_id"
        private const val PREF_RINGTONE_CHOICE = "flutter.circle_connect_ringtone_choice"
        private const val PREF_RINGTONE_URI = "flutter.circle_connect_ringtone_uri"
        private const val PREF_RINGTONE_SOUND_ID = "flutter.circle_connect_ringtone_sound_id"
        private const val PREF_CALLS_CHANNEL_VER = "flutter.circle_connect_calls_channel_version"
        private const val PREF_NOTIF_CHOICE = "flutter.circle_connect_notification_choice"
        private const val PREF_NOTIF_URI = "flutter.circle_connect_notification_uri"
        private const val PREF_NOTIF_SOUND_ID = "flutter.circle_connect_notification_sound_id"
        private const val PREF_MESSAGES_CHANNEL_VER = "flutter.circle_connect_messages_channel_version"
    }

    private lateinit var wifiNativeBridge: WifiNativeBridge
    private var incomingRingtone: Ringtone? = null
    private var previewRingtone: Ringtone? = null
    private var pendingRingtoneResult: MethodChannel.Result? = null
    private var pendingRingtoneKind: String? = null
    private var pendingRequestId: String? = null
    private val callWebViewHandler = Handler(Looper.getMainLooper())
    private val resumeCallWebViewRunnable = Runnable {
        if (OngoingCallService.isCallActive) {
            resumeCallWebViews()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createDefaultNotificationChannels()
        wakeAndUnlock()
    }

    private fun createDefaultNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

            // Channel Groups
            notificationManager.createNotificationChannelGroup(
                NotificationChannelGroup("grid_chat_messages", "GRID Chat messages")
            )
            notificationManager.createNotificationChannelGroup(
                NotificationChannelGroup("grid_chat_activity", "GRID Chat activity")
            )

            // 1. Calls channel (in GRID Chat messages group, with user's saved ringtone)
            val ringtoneUri = getSavedRingtoneUri()
            val callsChannel = NotificationChannel(
                "calls",
                "Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                group = "grid_chat_messages"
                description = "Circle Connect incoming voice and video calls"
                enableLights(true)
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                val audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                setSound(ringtoneUri, audioAttributes)
            }
            notificationManager.createNotificationChannel(callsChannel)

            // 2. Messages channels (in GRID Chat messages group, with user's saved notification sound)
            val notifUri = getSavedNotificationUri()
            val msgAudioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            val messagesChannel = NotificationChannel(
                "messages",
                "Messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                group = "grid_chat_messages"
                description = "Circle Connect direct chat messages"
                enableLights(true)
                enableVibration(true)
                setSound(notifUri, msgAudioAttributes)
            }
            notificationManager.createNotificationChannel(messagesChannel)

            val groupMessagesChannel = NotificationChannel(
                "group_messages",
                "Group messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                group = "grid_chat_messages"
                description = "Circle Connect group chat messages"
                enableLights(true)
                enableVibration(true)
                setSound(notifUri, msgAudioAttributes)
            }
            notificationManager.createNotificationChannel(groupMessagesChannel)

            // 3. Missed calls channel (in GRID Chat messages group)
            val missedCallsChannel = NotificationChannel(
                "missed_calls",
                "Missed calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                group = "grid_chat_messages"
                description = "Circle Connect missed call notifications"
                enableLights(true)
                enableVibration(true)
            }
            notificationManager.createNotificationChannel(missedCallsChannel)

            // 4. Professional Space (GRID) notification channel
            val activityChannel = NotificationChannel(
                "grid_activity",
                "Professional Space",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for posts, comments, connections, and activity in Professional Space"
                enableLights(true)
                enableVibration(true)
                setShowBadge(true)
            }
            notificationManager.createNotificationChannel(activityChannel)

            // Clean up old legacy channels that show under "Other"
            val channels = notificationManager.notificationChannels
            for (ch in channels) {
                if (ch.id.startsWith("grid_calls") || ch.id.startsWith("grid_messages")) {
                    try {
                        notificationManager.deleteNotificationChannel(ch.id)
                    } catch (_: Exception) {}
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Bring this same Activity forward. Do not load the chat URL again.
        setIntent(intent)
        wakeAndUnlock()
    }

    private fun wakeAndUnlock() {
        Log.i("FCM_DEBUG", "[NATIVE_WAKE] MainActivity.wakeAndUnlock() triggered: turning screen ON & dismissing keyguard")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguardManager?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiNativeBridge = WifiNativeBridge(this)
        wifiNativeBridge.register(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tech.efactor/circle_connect").setMethodCallHandler { call, result ->
            when (call.method) {
                "wakeAndUnlock" -> {
                    wakeAndUnlock()
                    result.success(true)
                }
                "getCookies" -> {
                    val url = call.argument<String>("url") ?: "https://efactor.tech"
                    val cookies = CookieManager.getInstance().getCookie(url) ?: ""
                    result.success(cookies)
                }
                "canDrawOverlays" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(Settings.canDrawOverlays(this))
                    } else {
                        result.success(true)
                    }
                }
                "openOverlaySettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            ).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("OVERLAY_ERROR", e2.message, null)
                            }
                        }
                    } else {
                        result.success(true)
                    }
                }
                "openNotificationChannelSettings" -> {
                    val channelId = call.argument<String>("channelId") ?: "calls"
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("CHANNEL_SETTINGS_ERROR", e2.message, null)
                        }
                    }
                }
                "openAppNotificationSettings", "openNotificationSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("APP_NOTIF_SETTINGS_ERROR", e2.message, null)
                        }
                    }
                }
                "openFullScreenIntentSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val intent = Intent("android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT").apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "isIgnoringBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                        result.success(pm?.isIgnoringBatteryOptimizations(packageName) ?: true)
                    } else {
                        result.success(true)
                    }
                }
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val fallbackIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(fallbackIntent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("BATTERY_OPTI_ERROR", e2.message, null)
                            }
                        }
                    } else {
                        result.success(true)
                    }
                }
                "openAutostartSettings" -> {
                    val opened = openOemAutostartSettings()
                    result.success(opened)
                }
                "getDeviceManufacturer" -> {
                    result.success(Build.MANUFACTURER.lowercase())
                }
                "startOngoingCallService" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    val callType = call.argument<String>("callType") ?: "audio"
                    val name = call.argument<String>("name") ?: ""
                    val isGroup = call.argument<Boolean>("isGroup") ?: false

                    val serviceIntent = Intent(this, OngoingCallService::class.java).apply {
                        action = OngoingCallService.ACTION_START_CALL
                        putExtra(OngoingCallService.EXTRA_CALL_ID, callId)
                        putExtra(OngoingCallService.EXTRA_CALL_TYPE, callType)
                        putExtra(OngoingCallService.EXTRA_NAME, name)
                        putExtra(OngoingCallService.EXTRA_IS_GROUP, isGroup)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ContextCompat.startForegroundService(this, serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    result.success(true)
                }
                "stopOngoingCallService" -> {
                    val serviceIntent = Intent(this, OngoingCallService::class.java).apply {
                        action = OngoingCallService.ACTION_STOP_CALL
                    }
                    startService(serviceIntent)
                    result.success(true)
                }
                "isOngoingCallActive" -> {
                    result.success(OngoingCallService.isCallActive)
                }
                "startIncomingRing" -> {
                    startIncomingRing()
                    result.success(true)
                }
                "stopIncomingRing" -> {
                    stopIncomingRing()
                    result.success(true)
                }
                "pickSystemSound" -> {
                    val kind = call.argument<String>("kind") ?: "ringtone"
                    val requestId = call.argument<String>("requestId") ?: ""
                    val currentUri = call.argument<String>("currentUri") ?: ""

                    pendingRingtoneResult = result
                    pendingRingtoneKind = kind
                    pendingRequestId = requestId

                    val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                        val type = if (kind == "notification") RingtoneManager.TYPE_NOTIFICATION else RingtoneManager.TYPE_RINGTONE
                        putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, type)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
                        if (currentUri.isNotBlank()) {
                            try {
                                putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, Uri.parse(currentUri))
                            } catch (_: Exception) {}
                        }
                    }
                    try {
                        startActivityForResult(intent, REQUEST_CODE_RINGTONE_PICKER)
                    } catch (e: Exception) {
                        pendingRingtoneResult = null
                        pendingRingtoneKind = null
                        pendingRequestId = null
                        result.error("PICKER_ERROR", e.message, null)
                    }
                }
                "setAppSound" -> {
                    val kind = call.argument<String>("kind") ?: "ringtone"
                    val choice = call.argument<String>("choice") ?: "phone_default"
                    val uri = call.argument<String>("uri") ?: ""
                    val soundId = call.argument<String>("soundId") ?: ""
                    handleSetAppSound(kind, choice, uri, soundId, result)
                }
                "playAppSound" -> {
                    val kind = call.argument<String>("kind") ?: "ringtone"
                    handlePlayAppSound(kind, result)
                }
                "stopAppSound" -> {
                    stopPreviewSound()
                    result.success(true)
                }
                "getActiveNotificationChannels" -> {
                    val prefs = getPrefs()
                    val callsChannelId = prefs.getString(PREF_CALLS_CHANNEL_ID, "calls") ?: "calls"
                    val messagesChannelId = prefs.getString(PREF_MESSAGES_CHANNEL_ID, "messages") ?: "messages"
                    result.success(mapOf(
                        "callsChannelId" to callsChannelId,
                        "messagesChannelId" to messagesChannelId
                    ))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onPause() {
        super.onPause()
        scheduleCallWebViewResume()
    }

    override fun onStop() {
        super.onStop()
        // Home / Recents hides the window after onPause, and WebView pauses itself then.
        scheduleCallWebViewResume()
    }

    override fun onResume() {
        callWebViewHandler.removeCallbacks(resumeCallWebViewRunnable)
        super.onResume()
    }

    /**
     * Flutter calls WebView.onPause() after the Activity pauses. Timers alone
     * do not restore the mic and camera. onResume() on the same WebView does.
     */
    private fun scheduleCallWebViewResume() {
        if (!OngoingCallService.isCallActive) return
        resumeCallWebViews()
        callWebViewHandler.removeCallbacks(resumeCallWebViewRunnable)
        window?.decorView?.post(resumeCallWebViewRunnable)
        callWebViewHandler.postDelayed(resumeCallWebViewRunnable, 250)
    }

    private fun resumeCallWebViews() {
        val root = window?.decorView ?: return
        resumeWebViewTree(root)
    }

    private fun resumeWebViewTree(view: View) {
        if (view is WebView) {
            try {
                view.onResume()
                view.resumeTimers()
            } catch (_: Exception) {
            }
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                resumeWebViewTree(view.getChildAt(i))
            }
        }
    }

    private fun openOemAutostartSettings(): Boolean {
        val autostartIntents = listOf(
            // Xiaomi / Poco / Redmi
            Intent().setComponent(ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
            // Vivo / iQOO
            Intent().setComponent(ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
            Intent().setComponent(ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
            Intent().setComponent(ComponentName("com.iqoo.secure", "com.iqoo.secure.MainGuideActivity")),
            // Oppo / Realme
            Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
            // Huawei / Honor
            Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity")),
            Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity")),
            // Samsung Device Care
            Intent().setComponent(ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity")),
            Intent().setComponent(ComponentName("com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity"))
        )

        for (intent in autostartIntents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {}
        }

        // Generic fallback to Application Details Settings
        try {
            val genericIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(genericIntent)
            return true
        } catch (_: Exception) {
            return false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_RINGTONE_PICKER) {
            val res = pendingRingtoneResult
            val reqId = pendingRequestId ?: ""
            val kind = pendingRingtoneKind ?: "ringtone"
            pendingRingtoneResult = null
            pendingRequestId = null
            pendingRingtoneKind = null

            if (resultCode == RESULT_OK && data != null) {
                val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
                }
                if (uri != null) {
                    val title = try {
                        RingtoneManager.getRingtone(applicationContext, uri)?.getTitle(applicationContext) ?: "Selected Sound"
                    } catch (_: Exception) {
                        "Selected Sound"
                    }
                    res?.success(mapOf(
                        "requestId" to reqId,
                        "kind" to kind,
                        "uri" to uri.toString(),
                        "title" to title,
                        "cancelled" to false
                    ))
                    return
                }
            }
            res?.success(mapOf(
                "requestId" to reqId,
                "kind" to kind,
                "cancelled" to true
            ))
        }
    }

    private fun getPrefs(): SharedPreferences {
        return getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun getSavedRingtoneUri(): Uri? {
        val prefs = getPrefs()
        val choice = prefs.getString(PREF_RINGTONE_CHOICE, "phone_default") ?: "phone_default"
        val uriStr = prefs.getString(PREF_RINGTONE_URI, "") ?: ""
        val soundId = prefs.getString(PREF_RINGTONE_SOUND_ID, "") ?: ""
        return resolveSoundUri("ringtone", choice, uriStr, soundId)
    }

    private fun getSavedNotificationUri(): Uri? {
        val prefs = getPrefs()
        val choice = prefs.getString(PREF_NOTIF_CHOICE, "phone_default") ?: "phone_default"
        val uriStr = prefs.getString(PREF_NOTIF_URI, "") ?: ""
        val soundId = prefs.getString(PREF_NOTIF_SOUND_ID, "") ?: ""
        return resolveSoundUri("notification", choice, uriStr, soundId)
    }

    private fun resolveSoundUri(kind: String, choice: String, uriStr: String, soundId: String): Uri? {
        val isRingtone = (kind == "ringtone")
        val defaultUri = if (isRingtone) {
            Settings.System.DEFAULT_RINGTONE_URI
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        } else {
            Settings.System.DEFAULT_NOTIFICATION_URI
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        }

        return when (choice) {
            "phone_sound" -> {
                if (uriStr.isNotBlank()) {
                    try {
                        Uri.parse(uriStr)
                    } catch (_: Exception) {
                        defaultUri
                    }
                } else {
                    defaultUri
                }
            }
            "app_sound" -> {
                if (soundId.isNotBlank()) {
                    val rawName = soundId.replace('-', '_').lowercase()
                    val resId = resources.getIdentifier(rawName, "raw", packageName)
                    if (resId != 0) {
                        Uri.parse("android.resource://$packageName/raw/$rawName")
                    } else {
                        defaultUri
                    }
                } else {
                    defaultUri
                }
            }
            "custom", "phone_default" -> defaultUri
            else -> defaultUri
        }
    }

    private fun handleSetAppSound(
        kind: String,
        choice: String,
        uri: String,
        soundId: String,
        result: MethodChannel.Result
    ) {
        val prefs = getPrefs()
        val isRingtone = (kind == "ringtone")
        val choicePref = if (isRingtone) PREF_RINGTONE_CHOICE else PREF_NOTIF_CHOICE
        val uriPref = if (isRingtone) PREF_RINGTONE_URI else PREF_NOTIF_URI
        val soundIdPref = if (isRingtone) PREF_RINGTONE_SOUND_ID else PREF_NOTIF_SOUND_ID
        val channelIdPref = if (isRingtone) PREF_CALLS_CHANNEL_ID else PREF_MESSAGES_CHANNEL_ID
        val targetChannelId = if (isRingtone) "calls" else "messages"

        val oldChoice = prefs.getString(choicePref, "") ?: ""
        val oldUri = prefs.getString(uriPref, "") ?: ""
        val oldSoundId = prefs.getString(soundIdPref, "") ?: ""
        val currentChannelId = prefs.getString(channelIdPref, targetChannelId) ?: targetChannelId

        // If nothing changed, do not recreate channel
        if (oldChoice == choice && oldUri == uri && oldSoundId == soundId && prefs.contains(channelIdPref)) {
            result.success(mapOf("changed" to false, "channelId" to currentChannelId))
            return
        }

        val resolvedUri = resolveSoundUri(kind, choice, uri, soundId)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            if (notificationManager != null) {
                if (isRingtone) {
                    try {
                        notificationManager.deleteNotificationChannel("calls")
                    } catch (_: Exception) {}

                    val channel = NotificationChannel(
                        "calls",
                        "Calls",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        group = "grid_chat_messages"
                        description = "Circle Connect incoming voice and video calls"
                        enableVibration(true)
                        enableLights(true)
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                        val audioAttributes = AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                        setSound(resolvedUri, audioAttributes)
                    }
                    notificationManager.createNotificationChannel(channel)
                } else {
                    try {
                        notificationManager.deleteNotificationChannel("messages")
                        notificationManager.deleteNotificationChannel("group_messages")
                    } catch (_: Exception) {}

                    val audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()

                    val directMsgChannel = NotificationChannel(
                        "messages",
                        "Messages",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        group = "grid_chat_messages"
                        description = "Circle Connect direct chat messages"
                        enableVibration(true)
                        enableLights(true)
                        setSound(resolvedUri, audioAttributes)
                    }
                    notificationManager.createNotificationChannel(directMsgChannel)

                    val groupMsgChannel = NotificationChannel(
                        "group_messages",
                        "Group messages",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        group = "grid_chat_messages"
                        description = "Circle Connect group chat messages"
                        enableVibration(true)
                        enableLights(true)
                        setSound(resolvedUri, audioAttributes)
                    }
                    notificationManager.createNotificationChannel(groupMsgChannel)
                }
            }
        }

        prefs.edit()
            .putString(choicePref, choice)
            .putString(uriPref, uri)
            .putString(soundIdPref, soundId)
            .putString(channelIdPref, targetChannelId)
            .apply()

        Log.i("MainActivity", "[SOUND] Updated $kind sound to choice=$choice, channel=$targetChannelId")
        result.success(mapOf("changed" to true, "channelId" to targetChannelId))
    }

    private fun handlePlayAppSound(kind: String, result: MethodChannel.Result) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (audioManager != null && audioManager.ringerMode != AudioManager.RINGER_MODE_NORMAL) {
            Log.i("MainActivity", "[SOUND] Skipping playAppSound because ringerMode is ${audioManager.ringerMode}")
            result.success(false)
            return
        }

        stopPreviewSound()

        val isRingtone = (kind == "ringtone")
        val resolvedUri = if (isRingtone) getSavedRingtoneUri() else getSavedNotificationUri()

        try {
            val tone = RingtoneManager.getRingtone(applicationContext, resolvedUri)
            if (tone != null) {
                val usage = if (isRingtone) AudioAttributes.USAGE_NOTIFICATION_RINGTONE else AudioAttributes.USAGE_NOTIFICATION
                tone.audioAttributes = AudioAttributes.Builder()
                    .setUsage(usage)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    tone.isLooping = isRingtone
                }
                tone.play()
                previewRingtone = tone
                result.success(true)
                return
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "playAppSound failed: ${e.message}")
        }
        result.success(false)
    }

    private fun stopPreviewSound() {
        try {
            previewRingtone?.stop()
        } catch (_: Exception) {}
        previewRingtone = null
    }

    override fun onDestroy() {
        stopIncomingRing()
        stopPreviewSound()
        callWebViewHandler.removeCallbacks(resumeCallWebViewRunnable)
        if (::wifiNativeBridge.isInitialized) {
            wifiNativeBridge.dispose()
        }
        super.onDestroy()
    }

    private fun startIncomingRing() {
        stopIncomingRing()
        try {
            val uri = getSavedRingtoneUri()
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val tone = RingtoneManager.getRingtone(applicationContext, uri)
            tone?.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                tone?.isLooping = true
            }
            tone?.play()
            incomingRingtone = tone
        } catch (e: Exception) {
            Log.w("IncomingRing", "ringtone failed: ${e.message}")
        }
        try {
            val pattern = longArrayOf(0, 700, 500, 700, 800)
            val vibrator = incomingVibrator()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            Log.w("IncomingRing", "vibrate failed: ${e.message}")
        }
    }

    private fun stopIncomingRing() {
        try {
            incomingRingtone?.stop()
        } catch (_: Exception) {
        }
        incomingRingtone = null
        try {
            incomingVibrator()?.cancel()
        } catch (_: Exception) {
        }
    }

    private fun incomingVibrator(): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }
}
