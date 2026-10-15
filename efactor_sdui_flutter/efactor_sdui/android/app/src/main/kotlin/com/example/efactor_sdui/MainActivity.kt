package com.example.efactor_sdui

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

import android.webkit.CookieManager
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiNativeBridge = WifiNativeBridge(this)
        wifiNativeBridge.register(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tech.efactor/circle_connect").setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url") ?: "https://efactor.tech"
                    val cookies = CookieManager.getInstance().getCookie(url) ?: ""
                    result.success(cookies)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (::wifiNativeBridge.isInitialized) {
            wifiNativeBridge.dispose()
        }
        super.onDestroy()
    }
}
