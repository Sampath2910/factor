-dontshrink
-dontoptimize

# R8: ignore harmless missing-class warnings from JVM string-concat desugaring
# (StringConcatFactory is a JVM detail R8 can't resolve on Android; safe to ignore).
-dontwarn java.lang.invoke.**
-dontwarn java.lang.invoke.StringConcatFactory

# ─────────────────────────────────────────────────────────────────────────
# FLUTTER PLUGIN — MUST keep the registration class intact (its name is how
# Flutter registers the plugin). This is in the efactor_provisioning package,
# NOT proto. Added for the Flutter-plugin AAR distribution.
# ─────────────────────────────────────────────────────────────────────────
-keep class tech.efactor.efactor_provisioning.EfactorProvisioningPlugin { *; }
# The Kotlin bridges/managers the plugin calls into (public API surface):
-keep class tech.efactor.proto.EfactorProvisioningBridge { *; }
-keep class tech.efactor.proto.EfactorDiscoveryBridge { *; }
-keep class tech.efactor.proto.EfactorDataBridge { *; }
-keepclassmembers class tech.efactor.proto.EfactorCloudManager { public <methods>; }

# Keep all classes except EfactorDevice (your original selective rule)
-keep class !tech.efactor.proto.EfactorDevice, !tech.efactor.proto.NodeManager,
!tech.efactor.proto.mDNSManager,!tech.efactor.proto.ApiClient,
!tech.efactor.proto.NodeResponseProcessor,!tech.efactor.proto.DeviceOperationRequest,
!tech.efactor.proto.EfactorCloudManager,
!tech.efactor.proto.JsonDataParser,
!tech.efactor.proto.EfactorLocalDevice,
tech.efactor.proto.** { *; }

# Keep all public methods of JsonDataParser
-keepclassmembers class tech.efactor.proto.JsonDataParser {
    public <methods>;
}

# Keep all public methods of NodeResponseProcessor
-keepclassmembers class tech.efactor.proto.NodeResponseProcessor {
    public <methods>;
}

# Keep all public methods of EfactorDevice
-keepclassmembers class tech.efactor.proto.EfactorDevice {
    public <methods>;
}
# Keep all public methods of EfactorCloudManager
-keepclassmembers class tech.efactor.proto.EfactorCloudManager {
    public <methods>;
}
# Allow obfuscation of private methods and fields
-keepclassmembers,allowobfuscation class tech.efactor.proto.EfactorCloudManager {
    private <methods>;
}
# Keep all public methods of mDNSManager
-keepclassmembers class tech.efactor.proto.mDNSManager {
    public <methods>;
}
# Keep all public methods of NodeManager
-keepclassmembers class tech.efactor.proto.NodeManager {
    public <methods>;
}
# Keep all public methods of ApiClient
-keepclassmembers class tech.efactor.proto.ApiClient {
    public <methods>;
}
# JNI native methods (DeviceHelper etc.)
-keepclassmembers class * {
    native <methods>;
}
# Allow obfuscation of private methods and fields
-keepclassmembers,allowobfuscation class tech.efactor.proto.EfactorDevice {
    private <methods>;
}

# Keep BuildConfig class and its fields from obfuscation
-keep class tech.efactor.efactorproto.BuildConfig {
    *;
}

# Protobuf / crypto / eventbus
-keep class efactor.** { *; }
-keep class cloud.** {*;}
-keep class efactor_claim.** {*;}
-keep class efactor_local_ctrl.** {*;}
-keep class efactor_mapping.** {*;}
-keep class com.google.protobuf.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keep class com.google.crypto.tink.** { *; }
-keepclassmembers class * extends com.google.crypto.tink.proto.Keyset { *; }
-keep class org.greenrobot.eventbus.** { *; }
-keepclassmembers class * {
    @org.greenrobot.eventbus.Subscribe <methods>;
}
-keep class com.google.android.gms.vision.** { *; }

# Specific classes to keep
-keep class tech.efactor.proto.CameraSource { *; }
-keep class tech.efactor.proto.EfactorProvisionManager { *; }

# Keep inner and synthetic classes
-keep class tech.efactor.proto.CameraSource$$* { *; }

# Keep transport and scanner classes
-keep class tech.efactor.proto.transport.** { *; }
-keep class tech.efactor.proto.device_scanner.** { *; }

# Preserve Runnables or background tasks
-keepclassmembers class tech.efactor.proto.EfactorDevice {
    private java.lang.Runnable *;
}

# Preserve access to WiFi/network-related permission methods
-keepclassmembers class tech.efactor.proto.EfactorDevice {
    @androidx.annotation.RequiresPermission *;
}

# Preserve listener classes
-keep class tech.efactor.proto.listeners.** { *; }

# ─────────────────────────────────────────────────────────────────────────
# NOTE ON LOG STRIPPING:
# We intentionally keep -dontoptimize for stability, which means Log calls are
# NOT stripped by ProGuard. The IP/port leak to the CLIENT APP is already fixed
# at the event level (discovery events no longer carry ip/port). SDK-owned logs
# are gated by BuildConfig.ENABLE_*_LOGS (set them false for release).
#
# If later you want to physically strip ALL android.util.Log calls, REMOVE the
# -dontoptimize line above and UNCOMMENT the block below, then RE-TEST all
# features (optimization can change behavior):
#
# -assumenosideeffects class android.util.Log {
#     public static int v(...);
#     public static int d(...);
#     public static int i(...);
#     public static int w(...);
#     public static int e(...);
#     public static int wtf(...);
#     public static boolean isLoggable(...);
# }
# ─────────────────────────────────────────────────────────────────────────