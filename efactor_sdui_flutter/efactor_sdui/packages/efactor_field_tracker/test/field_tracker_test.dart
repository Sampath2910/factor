import 'package:efactor_field_tracker/efactor_field_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackingPolicy', () {
    test('parses the backend effective-policy sample', () {
      final json = <String, dynamic>{
        'status': 'success',
        'v': '1',
        'policy': {
          'id': 1,
          'name': 'default_field_tracker',
          'mode': 'interval',
          'interval_seconds': 5,
          'geofence': null,
          'upload': {
            'batch_max_points': 50,
            'batch_max_interval_seconds': 60,
            'wifi_only': false,
          },
          'events': {'check_in_out_enabled': true},
          'retention_days': 90,
        },
      };
      final p = TrackingPolicy.fromResponse(json);
      expect(p.version, '1');
      expect(p.mode, 'interval');
      expect(p.intervalSeconds, 5);
      expect(p.batchMaxPoints, 50);
      expect(p.batchMaxIntervalSeconds, 60);
      expect(p.wifiOnly, false);
      expect(p.checkInOutEnabled, true);
      expect(p.retentionDays, 90);
    });

    test('round-trips through the cache encoding', () {
      final p = TrackingPolicy.fromResponse({
        'v': '7',
        'policy': {'mode': 'interval', 'interval_seconds': 10},
      });
      final back = TrackingPolicy.tryDecode(p.encode());
      expect(back, isNotNull);
      expect(back!.version, '7');
      expect(back.intervalSeconds, 10);
    });

    test('parses v2 background block and survives the cache round-trip', () {
      final p = TrackingPolicy.fromResponse({
        'v': '2',
        'policy': {
          'mode': 'interval',
          'interval_seconds': 5,
          'background': {
            'enabled': true,
            'interval_seconds': null,
            'distance_meters': null,
            'mode': 'interval',
          },
        },
      });
      expect(p.backgroundEnabled, true);
      expect(p.backgroundIntervalSeconds, isNull); // null => use interval_seconds
      expect(p.backgroundDistanceMeters, isNull);
      expect(p.backgroundMode, 'interval');

      final back = TrackingPolicy.tryDecode(p.encode())!;
      expect(back.backgroundEnabled, true);
      expect(back.backgroundMode, 'interval');
    });

    test('defaults background to disabled when absent (v1 response)', () {
      final p = TrackingPolicy.fromResponse({
        'v': '1',
        'policy': {'mode': 'interval', 'interval_seconds': 5},
      });
      expect(p.backgroundEnabled, false);
      expect(p.backgroundMode, 'same');
    });
  });

  group('resolveSampling (Phase 5 policy.background)', () {
    TrackingPolicy policy(Map<String, dynamic> p) =>
        TrackingPolicy.fromResponse({'v': '2', 'policy': p});

    test('foreground always follows top-level interval', () {
      final p = policy({'mode': 'interval', 'interval_seconds': 5});
      expect(
        resolveSampling(p, isForeground: true),
        const SamplingConfig(intervalSeconds: 5),
      );
    });

    test('backgrounded + background disabled => do not sample', () {
      final p = policy({
        'interval_seconds': 5,
        'background': {'enabled': false},
      });
      expect(resolveSampling(p, isForeground: false), isNull);
    });

    test('backgrounded interval, null interval falls back to top-level', () {
      final p = policy({
        'interval_seconds': 5,
        'background': {
          'enabled': true,
          'mode': 'interval',
          'interval_seconds': null,
        },
      });
      expect(
        resolveSampling(p, isForeground: false),
        const SamplingConfig(intervalSeconds: 5),
      );
    });

    test('backgrounded distance mode uses distance_meters', () {
      final p = policy({
        'interval_seconds': 5,
        'background': {
          'enabled': true,
          'mode': 'distance',
          'interval_seconds': 30,
          'distance_meters': 50,
        },
      });
      expect(
        resolveSampling(p, isForeground: false),
        const SamplingConfig(intervalSeconds: 30, distanceMeters: 50),
      );
    });

    test('backgrounded mode "same" reuses the top-level mode (interval)', () {
      final p = policy({
        'mode': 'interval',
        'interval_seconds': 5,
        'background': {'enabled': true, 'mode': 'same', 'interval_seconds': 20},
      });
      expect(
        resolveSampling(p, isForeground: false),
        const SamplingConfig(intervalSeconds: 20),
      );
    });
  });

  group('Breadcrumb', () {
    test('toJson matches the wire shape and uses UTC Z', () {
      final b = Breadcrumb(
        clientUuid: 'u-1',
        recordedAt: DateTime.utc(2026, 11, 20, 4, 0, 0),
        lat: 12.9716,
        lng: 77.5946,
        accuracyM: 8.5,
        speedMps: 1.2,
        heading: 90,
        altitudeM: 920,
        batteryPct: 81,
        provider: 'gps',
      );
      final j = b.toJson();
      expect(j['client_uuid'], 'u-1');
      expect(j['recorded_at'], '2026-11-20T04:00:00.000Z');
      expect(j['lat'], 12.9716);
      expect(j['lng'], 77.5946);
      expect(j['accuracy_m'], 8.5);
      expect(j['provider'], 'gps');
    });

    test('store round-trip preserves fields', () {
      final b = Breadcrumb(
        recordedAt: DateTime.utc(2026, 1, 1),
        lat: 1,
        lng: 2,
      );
      final back = Breadcrumb.fromStore(b.toStore());
      expect(back.clientUuid, b.clientUuid);
      expect(back.lat, 1);
      expect(back.lng, 2);
    });
  });

  group('PrefsBreadcrumbOutbox (offline-first)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('enqueue → peek → remove drains correctly', () async {
      final outbox = PrefsBreadcrumbOutbox();
      final a = Breadcrumb(recordedAt: DateTime.utc(2026), lat: 1, lng: 1);
      final b = Breadcrumb(recordedAt: DateTime.utc(2026), lat: 2, lng: 2);
      await outbox.enqueue(a);
      await outbox.enqueue(b);
      expect(await outbox.count(), 2);

      final batch = await outbox.peek(10);
      expect(batch.length, 2);

      await outbox.remove([a.clientUuid]);
      expect(await outbox.count(), 1);
      final remaining = await outbox.peek(10);
      expect(remaining.single.clientUuid, b.clientUuid);
    });

    test('peek respects the batch limit', () async {
      final outbox = PrefsBreadcrumbOutbox();
      for (var i = 0; i < 5; i++) {
        await outbox.enqueue(
          Breadcrumb(recordedAt: DateTime.utc(2026), lat: i.toDouble(), lng: 0),
        );
      }
      expect((await outbox.peek(3)).length, 3);
      expect(await outbox.count(), 5);
    });
  });

  group('TrackerIdentity', () {
    test('stable device_id persists across resolves', () async {
      SharedPreferences.setMockInitialValues({});
      final store = TrackerIdentityStore();
      final id1 = await store.ensureDeviceId();
      final id2 = await store.ensureDeviceId();
      expect(id1, isNotEmpty);
      expect(id1, id2);
    });

    test('body and query carry all four scope fields', () {
      const id = TrackerIdentity(
        appId: 'efactor_field_tracker',
        tenantId: 'tenant_demo_001',
        userId: '42',
        deviceId: 'dev-1',
      );
      expect(id.body.keys, containsAll(['app_id', 'tenant_id', 'device_id', 'user_id']));
      expect(id.query['tenant_id'], 'tenant_demo_001');
    });
  });
}
