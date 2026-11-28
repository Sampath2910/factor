import 'package:efactor_sdui/services/ongoing_call_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tech.efactor/circle_connect');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('startCallAudio forwards the full payload', () async {
    await OngoingCallService.instance.startCallAudio(
      callId: 'c1',
      video: true,
      preferredRoute: 'bluetooth',
      focus: 'transient-voip',
    );
    expect(calls.single.method, 'startCallAudio');
    expect(calls.single.arguments, <String, dynamic>{
      'callId': 'c1',
      'video': true,
      'preferredRoute': 'bluetooth',
      'focus': 'transient-voip',
    });
  });

  test('setCallAudioRoute and endCallAudio forward the right methods',
      () async {
    await OngoingCallService.instance.setCallAudioRoute(
      routeId: 'buds-123',
      routeType: 'bluetooth',
      deviceName: 'Galaxy Buds2 Pro',
    );
    await OngoingCallService.instance.endCallAudio('c1');
    expect(calls.map((c) => c.method).toList(),
        <String>['setCallAudioRoute', 'endCallAudio']);
    expect(calls.first.arguments['routeId'], 'buds-123');
    expect(calls.last.arguments['callId'], 'c1');
  });

  test('native onAudioRoutesChanged emits on routesChanged', () async {
    final snapshot = {
      'selectedRouteId': 'buds-123',
      'routes': [
        {'id': 'phone', 'type': 'phone', 'label': 'Phone'},
        {'id': 'buds-123', 'type': 'bluetooth', 'label': 'Galaxy Buds2 Pro'},
      ],
    };
    final received = OngoingCallService.instance.routesChanged.first;

    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall('onAudioRoutesChanged', snapshot)),
      (_) {},
    );

    final got = await received;
    expect(got['selectedRouteId'], 'buds-123');
    expect((got['routes'] as List).length, 2);
  });
}
