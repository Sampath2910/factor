// Copyright 2025 Factor Enovations Pvt Ltd
// Licensed under the Apache License, Version 2.0.
//
// Objective-C++ bridge so Swift can call the shared native key provider.
// The implementation (DeviceHelperBridge.mm) forwards each call to the plain
// C++ core in keys_core.h/.cpp — the SAME core your Android native-lib.cpp
// wraps via JNI — so both platforms emit byte-identical key strings.
//
// Mirrors DeviceHelper.kt: named getters + getKey1..getKey138.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DeviceHelperBridge : NSObject

// ---- Named keys ----
+ (NSString *)getNativeKey1;  // native key 1
+ (NSString *)getNativeKey2;  // native key 2
+ (NSString *)getNativeUrl;  // native URL (BASE_URL + suffix)
+ (NSString *)getDefaultWifiBaseUrl;  // default Wi-Fi SoftAP base URL
+ (NSString *)getUserDescriptionUUID;  // user-description characteristic UUID
+ (NSString *)getHandlerProvSession;  // prov-session handler path
+ (NSString *)getHandlerProvScan;  // prov-scan handler path
+ (NSString *)getHandlerProtoVersion;  // proto-version handler path
+ (NSString *)getHandlerProvConfig;  // prov-config handler path
+ (NSString *)getHandlerEfactorCloudAssoc;  // cloud-assoc handler path
+ (NSString *)getMdnsServiceType;  // mDNS/Bonjour service type
+ (NSString *)getNativeApiKey;  // SoftAP base URL

// ---- Numbered keys getKey1..getKey138 ----
+ (NSString *)getKey1;
+ (NSString *)getKey2;
+ (NSString *)getKey3;
+ (NSString *)getKey4;
+ (NSString *)getKey5;
+ (NSString *)getKey6;
+ (NSString *)getKey7;
+ (NSString *)getKey8;
+ (NSString *)getKey9;
+ (NSString *)getKey10;
+ (NSString *)getKey11;
+ (NSString *)getKey12;
+ (NSString *)getKey13;
+ (NSString *)getKey14;
+ (NSString *)getKey15;
+ (NSString *)getKey16;
+ (NSString *)getKey17;
+ (NSString *)getKey18;
+ (NSString *)getKey19;
+ (NSString *)getKey20;
+ (NSString *)getKey21;
+ (NSString *)getKey22;
+ (NSString *)getKey23;
+ (NSString *)getKey24;
+ (NSString *)getKey25;
+ (NSString *)getKey26;
+ (NSString *)getKey27;
+ (NSString *)getKey28;
+ (NSString *)getKey29;
+ (NSString *)getKey30;
+ (NSString *)getKey31;
+ (NSString *)getKey32;
+ (NSString *)getKey33;
+ (NSString *)getKey34;
+ (NSString *)getKey35;
+ (NSString *)getKey36;
+ (NSString *)getKey37;
+ (NSString *)getKey38;
+ (NSString *)getKey39;
+ (NSString *)getKey40;
+ (NSString *)getKey41;
+ (NSString *)getKey42;
+ (NSString *)getKey43;
+ (NSString *)getKey44;
+ (NSString *)getKey45;
+ (NSString *)getKey46;
+ (NSString *)getKey47;
+ (NSString *)getKey48;
+ (NSString *)getKey49;
+ (NSString *)getKey50;
+ (NSString *)getKey51;
+ (NSString *)getKey52;
+ (NSString *)getKey53;
+ (NSString *)getKey54;
+ (NSString *)getKey55;
+ (NSString *)getKey56;
+ (NSString *)getKey57;
+ (NSString *)getKey58;
+ (NSString *)getKey59;
+ (NSString *)getKey60;
+ (NSString *)getKey61;
+ (NSString *)getKey62;
+ (NSString *)getKey63;
+ (NSString *)getKey64;
+ (NSString *)getKey65;
+ (NSString *)getKey66;
+ (NSString *)getKey67;
+ (NSString *)getKey68;
+ (NSString *)getKey69;
+ (NSString *)getKey70;
+ (NSString *)getKey71;
+ (NSString *)getKey72;
+ (NSString *)getKey73;
+ (NSString *)getKey74;
+ (NSString *)getKey75;
+ (NSString *)getKey76;
+ (NSString *)getKey77;
+ (NSString *)getKey78;
+ (NSString *)getKey79;
+ (NSString *)getKey80;
+ (NSString *)getKey81;
+ (NSString *)getKey82;
+ (NSString *)getKey83;
+ (NSString *)getKey84;
+ (NSString *)getKey85;
+ (NSString *)getKey86;
+ (NSString *)getKey87;
+ (NSString *)getKey88;
+ (NSString *)getKey89;
+ (NSString *)getKey90;
+ (NSString *)getKey91;
+ (NSString *)getKey92;
+ (NSString *)getKey93;
+ (NSString *)getKey94;
+ (NSString *)getKey95;
+ (NSString *)getKey96;
+ (NSString *)getKey97;
+ (NSString *)getKey98;
+ (NSString *)getKey99;
+ (NSString *)getKey100;
+ (NSString *)getKey101;
+ (NSString *)getKey102;
+ (NSString *)getKey103;
+ (NSString *)getKey104;
+ (NSString *)getKey105;
+ (NSString *)getKey106;
+ (NSString *)getKey107;
+ (NSString *)getKey108;
+ (NSString *)getKey109;
+ (NSString *)getKey110;
+ (NSString *)getKey111;
+ (NSString *)getKey112;
+ (NSString *)getKey113;
+ (NSString *)getKey114;
+ (NSString *)getKey115;
+ (NSString *)getKey116;
+ (NSString *)getKey117;
+ (NSString *)getKey118;
+ (NSString *)getKey119;
+ (NSString *)getKey120;
+ (NSString *)getKey121;
+ (NSString *)getKey122;
+ (NSString *)getKey123;
+ (NSString *)getKey124;
+ (NSString *)getKey125;
+ (NSString *)getKey126;
+ (NSString *)getKey127;
+ (NSString *)getKey128;
+ (NSString *)getKey129;
+ (NSString *)getKey130;
+ (NSString *)getKey131;
+ (NSString *)getKey132;
+ (NSString *)getKey133;
+ (NSString *)getKey134;
+ (NSString *)getKey135;
+ (NSString *)getKey136;
+ (NSString *)getKey137;
+ (NSString *)getKey138;

// ---- Convenience: fetch a numbered key by index (0 -> @"") ----
+ (NSString *)keyByIndex:(NSInteger)n;

@end

NS_ASSUME_NONNULL_END
