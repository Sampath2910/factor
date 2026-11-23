import 'package:efactor_sdui/services/field_tracking_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

FieldTrackingCommand _cmd({
  String action = 'start',
  String deviceId = '',
  String commandId = 'c1',
  int issuedAt = 1000,
}) =>
    FieldTrackingCommand(
      action: action,
      appId: 'efactor_field_tracker',
      tenantId: 'tenant_demo_001',
      userId: '42',
      deviceId: deviceId,
      commandId: commandId,
      issuedAt: issuedAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FieldTrackingCommand.tryParse', () {
    test('parses a field_tracking push (all-string payload)', () {
      final cmd = FieldTrackingCommand.tryParse(<String, dynamic>{
        'type': 'field_tracking',
        'action': 'start',
        'app_id': 'efactor_field_tracker',
        'tenant_id': 'tenant_demo_001',
        'user_id': '42',
        'device_id': '',
        'command_id': 'ft_abc',
        'issued_at': '1763900000',
      });
      expect(cmd, isNotNull);
      expect(cmd!.isStart, isTrue);
      expect(cmd.issuedAt, 1763900000);
      expect(cmd.scopeKey, 'efactor_field_tracker|tenant_demo_001|42');
    });

    test('returns null for a non-tracking push', () {
      expect(
        FieldTrackingCommand.tryParse(<String, dynamic>{'type': 'NEW_MESSAGE'}),
        isNull,
      );
    });
  });

  group('shouldApplyFieldTrackingCommand (pure idempotency gate)', () {
    bool apply(
      FieldTrackingCommand c, {
      String? ourDeviceId,
      int? lastIssued,
      Set<String> applied = const <String>{},
    }) =>
        shouldApplyFieldTrackingCommand(
          cmd: c,
          ourDeviceId: ourDeviceId,
          lastAppliedIssuedAt: lastIssued,
          appliedCommandIds: applied,
        );

    test('applies a fresh command with no prior state', () {
      expect(apply(_cmd()), isTrue);
    });

    test('rejects an unknown action', () {
      expect(apply(_cmd(action: 'pause')), isFalse);
    });

    test('rejects an already-applied command_id', () {
      expect(apply(_cmd(commandId: 'c1'), applied: {'c1'}), isFalse);
    });

    test('rejects a stale or equal issued_at (out-of-order push)', () {
      expect(apply(_cmd(issuedAt: 1000), lastIssued: 1000), isFalse);
      expect(apply(_cmd(issuedAt: 999), lastIssued: 1000), isFalse);
      expect(apply(_cmd(issuedAt: 1001), lastIssued: 1000), isTrue);
    });

    test('empty device_id targets every device of the user', () {
      expect(apply(_cmd(deviceId: ''), ourDeviceId: 'dev-xyz'), isTrue);
    });

    test('non-empty device_id must match this device', () {
      expect(apply(_cmd(deviceId: 'dev-xyz'), ourDeviceId: 'dev-xyz'), isTrue);
      expect(apply(_cmd(deviceId: 'dev-other'), ourDeviceId: 'dev-xyz'), isFalse);
      // targeted command but this device has no id yet → not us
      expect(apply(_cmd(deviceId: 'dev-xyz'), ourDeviceId: null), isFalse);
    });
  });

  group('FieldTrackingCommandStore (persisted gate state)', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('markApplied advances the watermark and blocks replays', () async {
      final store = FieldTrackingCommandStore.instance;
      await store.resetForTesting();
      final cmd = _cmd(commandId: 'c1', issuedAt: 1000);

      expect(await store.readLastIssuedAt(cmd.scopeKey), isNull);
      expect(await store.readAppliedIds(cmd.scopeKey), isEmpty);

      await store.markApplied(cmd);

      expect(await store.readLastIssuedAt(cmd.scopeKey), 1000);
      expect(await store.readAppliedIds(cmd.scopeKey), contains('c1'));

      // A replay (same id) and a stale one are both now rejected by the gate.
      expect(
        shouldApplyFieldTrackingCommand(
          cmd: cmd,
          ourDeviceId: null,
          lastAppliedIssuedAt: await store.readLastIssuedAt(cmd.scopeKey),
          appliedCommandIds: await store.readAppliedIds(cmd.scopeKey),
        ),
        isFalse,
      );
    });

    test('pending handoff keeps the newest command', () async {
      final store = FieldTrackingCommandStore.instance;
      await store.resetForTesting();

      await store.writePendingIfNewer(_cmd(commandId: 'old', issuedAt: 1000));
      await store.writePendingIfNewer(_cmd(commandId: 'new', issuedAt: 2000));
      await store.writePendingIfNewer(_cmd(commandId: 'older', issuedAt: 500));

      final pending = await store.readPending();
      expect(pending, isNotNull);
      expect(pending!.commandId, 'new');
      expect(pending.issuedAt, 2000);

      await store.clearPending();
      expect(await store.readPending(), isNull);
    });
  });
}
