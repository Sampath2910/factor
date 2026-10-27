package com.example.efactor_sdui

import android.app.KeyguardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
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
    private lateinit var wifiNativeBridge: WifiNativeBridge
    private var incomingRingtone: Ringtone? = null
    private val callWebViewHandler = Handler(Looper.getMainLooper())
    private val resumeCallWebViewRunnable = Runnable {
        if (OngoingCallService.isCallActive) {
            resumeCallWebViews()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        wakeAndUnlock()
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
                    val channelId = call.argument<String>("channelId") ?: "grid_calls_v4"
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
                "startIncomingRing" -> {
                    startIncomingRing()
                    result.success(true)
                }
                "stopIncomingRing" -> {
                    stopIncomingRing()
                    result.success(true)
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

    override fun onDestroy() {
        stopIncomingRing()
        callWebViewHandler.removeCallbacks(resumeCallWebViewRunnable)
        if (::wifiNativeBridge.isInitialized) {
            wifiNativeBridge.dispose()
        }
        super.onDestroy()
    }

    private fun startIncomingRing() {
        stopIncomingRing()
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val tone = RingtoneManager.getRingtone(applicationContext, uri)
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
