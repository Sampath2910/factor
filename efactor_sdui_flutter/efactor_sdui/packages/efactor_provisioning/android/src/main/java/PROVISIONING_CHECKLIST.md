# Provisioning files — drop-in checklist

Replace every DUMMY file below with your REAL one from efactorlib. Keep the exact
package/folder. Files marked ✅ you already shared (I have the real content, but
you still drop YOUR copy in — mine may be a placeholder if I couldn't include it).

## tech/efactor/proto/  (root)
- [✅] EfactorDevice.java                 (shared)
- [✅] EfactorProvisionManager.java       (shared)
- [✅] Session.java                        (shared)
- [✅] WiFiAccessPoint.java               (shared)
- [✅] EfactorConstants.java              (shared)
- [✅] DeviceConnectionEvent.java         (shared)
- [ ] EfactorConfig.java  ← if part of tech.efactor.proto (else it's efactor.*)

## tech/efactor/proto/security/
- [✅] Security.java                       (shared)
- [✅] Security0.java                      (shared)
- [✅] Security1.java                      (shared)

## tech/efactor/proto/transport/
- [✅] Transport.java                      (shared)
- [✅] SoftAPTransport.java                (shared)
- [✅] BLETransport.java                   (shared)
- [✅] Helper.java                         (shared — JNI, links native-lib)

## tech/efactor/proto/listeners/
- [✅] ResponseListener.java               (shared)
- [✅] WiFiScanListener.java               (shared)
- [DUMMY] ProvisionListener.java     ← REPLACE with real
- [DUMMY] ApiLibResponseListener.java ← REPLACE with real
- [DUMMY] BleScanListener.java        ← REPLACE with real
- [DUMMY] QRCodeScanListener.java     ← REPLACE with real

## tech/efactor/proto/utils/
- [DUMMY] HexEncoder.java             ← REPLACE with real (Security1 uses .xor())
- [DUMMY] MessengeHelper.java         ← REPLACE with real

## tech/efactor/proto/device_scanner/
- [DUMMY] BleScanner.java             ← REPLACE with real
- [DUMMY] WiFiScanner.java            ← REPLACE with real

## efactor.*  protobuf  (put .proto in android/src/main/proto/, OR generated .java under java/efactor/)

VERIFIED usage from EfactorDevice + Security0/1. You need protobuf classes providing:
- [ ] Sec0                          (Security0: S0SessionCmd, Sec0Payload)
- [ ] Sec1                          (Security1: SessionCmd0/1, Sec1Payload, Sec1MsgType)
- [ ] Session                       (Security0/1: SessionData, SecSchemeVersion)
                                     NOTE: efactor.Session ≠ tech.efactor.proto.Session
- [ ] WifiConfig                    (WiFiConfigPayload)
- [ ] WifiScan                      (RespScanResult, RespScanStart, RespScanStatus, WiFiScanPayload)
- [ ] WifiConstants                 (WifiConnectFailedReason, WifiStationState)
- [ ] Constants                     (Status, and enums)
- [ ] EfactorConfig                 (EfactorConfigResponse, EfactorConfigStatus)
- [ ] AppConstants                  (efactor.AppConstants — referenced too)

These come from .proto files. Standard ESP provisioning protos are:
  session.proto, sec0.proto, sec1.proto, wifi_config.proto, wifi_scan.proto,
  wifi_constants.proto, constants.proto  + your custom efactor_config.proto
Drop the .proto files in android/src/main/proto/ and Gradle generates the Java.

## Already in plugin — DO NOT add duplicates:
- DeviceHelper (Kotlin, tech.efactor.proto)
- mDNSManager, EfactorLocalDevice, DeviceDiscoveryEvent (from mDNS milestone)
- native-lib.cpp / keys_core (your real .cpp)

## Referenced by EfactorDevice but from other packages (may need later):
- efactor.EfactorConfig, efactor.WifiConstants  (the `import efactor.*` ones)
- ApiManager (HTTP — belongs to sendData milestone; EfactorDevice.pingLocalRunnable
  uses it. If provisioning references it, we stub temporarily.)
- models/EfactorNode.java

## ⚠️ The big open item: efactor.* protobuf
These are GENERATED. Find their `.proto` source in your efactorlib project
(look for src/main/proto/*.proto) and drop them in android/src/main/proto/.
The plugin's Gradle protobuf plugin will generate the Java at build time.
If you only have generated .java, put them under
android/src/main/java/efactor/  instead.
Provisioning CANNOT compile until these are present.
