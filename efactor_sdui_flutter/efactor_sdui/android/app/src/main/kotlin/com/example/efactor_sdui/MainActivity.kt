package com.example.efactor_sdui

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Application host.
 *
 * Efactor Cloud / Provision / Discovery / Data are registered automatically by
 * the local `efactor_provisioning` Flutter plugin.
 *
 * This activity registers only Android OS Wi-Fi capabilities required by the
 * schema-driven provisioning UI.
 */
class MainActivity : FlutterActivity() {
    private lateinit var wifiNativeBridge: WifiNativeBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiNativeBridge = WifiNativeBridge(this)
        wifiNativeBridge.register(flutterEngine)
    }

    override fun onDestroy() {
        if (::wifiNativeBridge.isInitialized) {
            wifiNativeBridge.dispose()
        }
        super.onDestroy()
    }
}
