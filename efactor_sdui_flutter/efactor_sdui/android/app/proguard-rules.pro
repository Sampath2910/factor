# ProGuard / R8 rules for okhttp3, bouncycastle, conscrypt, openjsse, slf4j

-dontwarn okhttp3.internal.platform.**
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.bouncycastle.jsse.provider.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-dontwarn org.openjsse.javax.net.ssl.**
-dontwarn org.openjsse.net.ssl.**
-dontwarn org.slf4j.impl.**

# Keep rules for Efactor SDK & dependencies
-keep class com.google.protobuf.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keep class org.greenrobot.eventbus.** { *; }

# --- Audit 5.2: R8 keep rules for release code shrinking ---

# WebView JS bridges: webview_flutter exposes @JavascriptInterface methods that
# R8 must not rename/strip, or the native<->web channels break.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class * extends android.webkit.WebChromeClient { *; }

# Firebase Cloud Messaging / push.
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Keep enum machinery (R8 can break valueOf()/values() used by name).
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Preserve annotations/signatures used by reflection-based libraries.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
