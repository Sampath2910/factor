# efactor_provisioning — consumer ProGuard/R8 rules.
# Shipped inside the module so they auto-apply to any host app's release build.

# ── JNI: native methods and the classes declaring them must NOT be renamed ──
-keepclasseswithmembernames class * {
    native <methods>;
}

# ── The whole efactor core (closed-source; DeviceHelper native methods +
#    generated protobuf). Broad keep = safe. ──
-keep class tech.efactor.** { *; }
-dontwarn tech.efactor.**

# ── Protobuf (javalite) ──
-keep class com.google.protobuf.** { *; }
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { *; }
-dontwarn com.google.protobuf.**

# ── Gson ──
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keep class com.google.gson.** { *; }
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-dontwarn com.google.gson.**

# ── EventBus ──
-keepclassmembers class * {
    @org.greenrobot.eventbus.Subscribe <methods>;
}
-keep enum org.greenrobot.eventbus.ThreadMode { *; }
-keep class org.greenrobot.eventbus.** { *; }
-dontwarn org.greenrobot.eventbus.**

# ── Tink ──
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# ── Java-WebSocket ──
-keep class org.java_websocket.** { *; }
-dontwarn org.java_websocket.**

# ── OkHttp / Okio ──
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# slf4j optional binding referenced by java-websocket; not present at runtime
-dontwarn org.slf4j.**
-dontwarn org.slf4j.impl.**
