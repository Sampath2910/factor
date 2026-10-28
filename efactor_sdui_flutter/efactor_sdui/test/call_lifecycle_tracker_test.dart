import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:efactor_sdui/services/call_lifecycle_tracker.dart';
import 'package:efactor_sdui/services/incoming_call_service.dart';
import 'package:efactor_sdui/services/ongoing_call_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CallLifecycleTracker.resetForTesting();
    IncomingCallService.instance.dismissCall();
    await OngoingCallService.instance.stopCall();
  });

  group('CallLifecycleTracker - Type classifications (A1)', () {
    test('kEndCallTypes contains all end and cancellation types', () {
      const expectedEndTypes = {
        'MISSED_CALL',
        'CALL_MISSED',
        'CALL_HANDLED',
        'CALL_CANCELLED',
        'CANCEL_CALL',
        'REJECTED',
        'HANGUP',
        'CALL_ENDED',
      };
      for (final type in expectedEndTypes) {
        expect(CallLifecycleTracker.kEndCallTypes.contains(type), isTrue,
            reason: '$type should be in kEndCallTypes');
      }
    });

    test('kRingCallTypes contains incoming and ring types', () {
      const expectedRingTypes = {
        'INCOMING_CALL',
        'CALL',
        'VOIP_CALL',
      };
      for (final type in expectedRingTypes) {
        expect(CallLifecycleTracker.kRingCallTypes.contains(type), isTrue,
            reason: '$type should be in kRingCallTypes');
      }
      expect(CallLifecycleTracker.kRingCallTypes.contains('MISSED_CALL'), isFalse);
      expect(CallLifecycleTracker.kRingCallTypes.contains('CALL_CANCELLED'), isFalse);
      expect(CallLifecycleTracker.kRingCallTypes.contains('CALL_ENDED'), isFalse);
    });
  });

  group('CallLifecycleTracker - Finished Calls Deduplication (A2)', () {
    test('marks call finished in memory and SharedPreferences', () async {
      const testCallId = 'call_abc_123';
      expect(CallLifecycleTracker.isCallFinishedSync(testCallId), isFalse);
      expect(await CallLifecycleTracker.isCallFinished(testCallId), isFalse);

      await CallLifecycleTracker.markCallFinished(testCallId);

      expect(CallLifecycleTracker.isCallFinishedSync(testCallId), isTrue);
      expect(await CallLifecycleTracker.isCallFinished(testCallId), isTrue);
    });

    test('multiple calls can be marked and tracked independently', () async {
      await CallLifecycleTracker.markCallFinished('call_1');
      await CallLifecycleTracker.markCallFinished('call_2');

      expect(await CallLifecycleTracker.isCallFinished('call_1'), isTrue);
      expect(await CallLifecycleTracker.isCallFinished('call_2'), isTrue);
      expect(await CallLifecycleTracker.isCallFinished('call_3'), isFalse);
    });
  });

  group('CallLifecycleTracker - Ongoing Call State Tracking (A2)', () {
    test('tracks ongoing call active status in SharedPreferences', () async {
      expect(await CallLifecycleTracker.isOngoingCallActive(), isFalse);

      await CallLifecycleTracker.setOngoingCallActive(true, callId: 'call_active_1');
      expect(await CallLifecycleTracker.isOngoingCallActive(), isTrue);
      // Also marks call_active_1 as finished ringing
      expect(await CallLifecycleTracker.isCallFinished('call_active_1'), isTrue);

      await CallLifecycleTracker.setOngoingCallActive(false, callId: 'call_active_1');
      expect(await CallLifecycleTracker.isOngoingCallActive(), isFalse);
      // Call remains in finished calls list
      expect(await CallLifecycleTracker.isCallFinished('call_active_1'), isTrue);
    });

    test('OngoingCallService startCall and stopCall sync active state', () async {
      await OngoingCallService.instance.startCall(
        callId: 'call_ongoing_test',
        callType: 'audio',
        name: 'Bob',
      );

      expect(OngoingCallService.instance.isCallActive, isTrue);
      expect(await CallLifecycleTracker.isOngoingCallActive(), isTrue);
      expect(await CallLifecycleTracker.isCallFinished('call_ongoing_test'), isTrue);

      await OngoingCallService.instance.stopCall('call_ongoing_test');

      expect(OngoingCallService.instance.isCallActive, isFalse);
      expect(await CallLifecycleTracker.isOngoingCallActive(), isFalse);
    });
  });

  group('IncomingCallService - Push handling with A1 & A2 rules', () {
    test('CALL_CANCELLED dismisses call immediately without waiting for timer', () async {
      final service = IncomingCallService.instance;

      service.handleIncomingPayload({
        'type': 'INCOMING_CALL',
        'call_id': 'call_quick_cancel',
        'caller_name': 'Tester',
      });
      expect(service.currentCall.value, isNotNull);

      // Caller cancels immediately
      service.handleIncomingPayload({
        'type': 'CALL_CANCELLED',
        'call_id': 'call_quick_cancel',
      });

      expect(service.currentCall.value, isNull);
      expect(await CallLifecycleTracker.isCallFinished('call_quick_cancel'), isTrue);
    });

    test('CALL_ENDED dismisses call immediately and marks finished', () async {
      final service = IncomingCallService.instance;

      service.handleIncomingPayload({
        'type': 'INCOMING_CALL',
        'call_id': 'call_quick_end',
        'caller_name': 'Tester',
      });
      expect(service.currentCall.value, isNotNull);

      service.handleIncomingPayload({
        'type': 'CALL_ENDED',
        'call_id': 'call_quick_end',
      });

      expect(service.currentCall.value, isNull);
      expect(await CallLifecycleTracker.isCallFinished('call_quick_end'), isTrue);
    });

    test('MISSED_CALL dismisses call immediately and marks finished', () async {
      final service = IncomingCallService.instance;

      service.handleIncomingPayload({
        'type': 'INCOMING_CALL',
        'call_id': 'call_missed_test',
        'caller_name': 'Tester',
      });
      expect(service.currentCall.value, isNotNull);

      service.handleIncomingPayload({
        'type': 'MISSED_CALL',
        'call_id': 'call_missed_test',
      });

      expect(service.currentCall.value, isNull);
      expect(await CallLifecycleTracker.isCallFinished('call_missed_test'), isTrue);
    });

    test('Never rings again for a call that is already over (A2)', () async {
      final service = IncomingCallService.instance;

      // Mark call as finished
      await CallLifecycleTracker.markCallFinished('call_finished_earlier');

      // Delayed or duplicate INCOMING_CALL arrives
      service.handleIncomingPayload({
        'type': 'INCOMING_CALL',
        'call_id': 'call_finished_earlier',
        'caller_name': 'Late Pusher',
      });

      // Must be ignored!
      expect(service.currentCall.value, isNull);
    });

    test('Never rings while OngoingCallService has an active call (A2)', () async {
      final service = IncomingCallService.instance;

      await OngoingCallService.instance.startCall(
        callId: 'current_active_call',
        callType: 'audio',
        name: 'Alice',
      );

      // A second incoming call push arrives while talking
      service.handleIncomingPayload({
        'type': 'INCOMING_CALL',
        'call_id': 'new_incoming_during_call',
        'caller_name': 'Third Party',
      });

      // Must not ring or start ringing notification!
      expect(service.currentCall.value, isNull);

      await OngoingCallService.instance.stopCall('current_active_call');
    });
  });
}
