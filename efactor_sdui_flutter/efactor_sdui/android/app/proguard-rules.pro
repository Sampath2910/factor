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
