import 'package:efactor_sdui/grid_sdui/grid_in_app_webview_page.dart';
import 'package:efactor_sdui/services/push_notification_bootstrap.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Professional Space (GRID) Push Detection', () {
    test('isProfessionalSpacePush identifies PROFESSIONAL_SPACE_EVENT type', () {
      expect(
        isProfessionalSpacePush({'type': 'PROFESSIONAL_SPACE_EVENT'}),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({'type': 'professional_space_event'}),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({'event': 'PROFESSIONAL_SPACE_EVENT'}),
        isTrue,
      );
    });

    test('isProfessionalSpacePush identifies grid_activity channel', () {
      expect(
        isProfessionalSpacePush({'channel': 'grid_activity'}),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({
          'type': 'POST_LIKE',
          'channel': 'grid_activity',
          'post_id': '582',
        }),
        isTrue,
      );
    });

    test('isProfessionalSpacePush identifies target_url containing /grid', () {
      expect(
        isProfessionalSpacePush({
          'target_url': 'https://efactor.tech/index.php/grid?post=582',
        }),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        }),
        isTrue,
      );
    });

    test('isProfessionalSpacePush excludes Circle Connect chat and activity', () {
      expect(
        isProfessionalSpacePush({
          'type': 'CHAT_MESSAGE',
          'conversation_id': '42',
          'channel': 'messages',
          'target_url': 'https://efactor.tech/index.php/grid-chat?conversation=42',
        }),
        isFalse,
      );
      expect(
        isProfessionalSpacePush({
          'type': 'ACTIVITY',
          'channel': 'mentions',
          'url': 'https://efactor.tech/index.php/grid-chat?open=activity',
        }),
        isFalse,
      );
    });
  });

  group('Professional Space Notification Channel', () {
    test('kGridActivityChannel is correctly defined with High importance', () {
      expect(kGridActivityChannel.id, equals('grid_activity'));
      expect(kGridActivityChannel.name, equals('Professional Space'));
      expect(
        kGridActivityChannel.description,
        equals(
          'Notifications for posts, comments, connections, and activity in Professional Space',
        ),
      );
      expect(kGridActivityChannel.importance, equals(Importance.high));
      expect(kGridActivityChannel.playSound, isTrue);
      expect(kGridActivityChannel.enableVibration, isTrue);
    });
  });

  group('URL Safety Validation', () {
    test('isSafeEfactorUrl validates efactor.tech hosts and blocks others', () {
      expect(isSafeEfactorUrl('https://efactor.tech/index.php/grid?post=582'), isTrue);
      expect(isSafeEfactorUrl('https://efactor.tech/index.php/grid/messaging?user=7'), isTrue);
      expect(isSafeEfactorUrl('https://chat.efactor.tech/index.php/grid'), isTrue);
      expect(isSafeEfactorUrl('https://google.com'), isFalse);
      expect(isSafeEfactorUrl('https://efactor.tech.attacker.com'), isFalse);
      expect(isSafeEfactorUrl('javascript:alert(1)'), isFalse);
      expect(isSafeEfactorUrl(''), isFalse);
    });
  });

  group('Cold Start Target URL Latching', () {
    setUp(() {
      GridInAppWebViewPage.clearPendingTargetUrl();
    });

    tearDown(() {
      GridInAppWebViewPage.clearPendingTargetUrl();
    });

    test('loadTargetUrl stores pending URL and notifies listeners on cold start', () async {
      const targetUrl = 'https://efactor.tech/index.php/grid?post=582';
      expect(GridInAppWebViewPage.pendingTargetUrl, isNull);

      var notifiedCount = 0;
      void listener() {
        notifiedCount++;
      }

      GridInAppWebViewPage.pendingTargetUrlListenable.addListener(listener);

      final accepted = await GridInAppWebViewPage.loadTargetUrl(targetUrl);
      expect(accepted, isTrue);
      expect(GridInAppWebViewPage.pendingTargetUrl, equals(targetUrl));
      expect(notifiedCount, greaterThan(0));

      GridInAppWebViewPage.clearPendingTargetUrl();
      expect(GridInAppWebViewPage.pendingTargetUrl, isNull);

      GridInAppWebViewPage.pendingTargetUrlListenable.removeListener(listener);
    });

    test('loadTargetUrl blocks malicious non-efactor URLs from latching', () async {
      const maliciousUrl = 'https://malicious-site.com/steal-token';
      final accepted = await GridInAppWebViewPage.loadTargetUrl(maliciousUrl);
      expect(accepted, isFalse);
      expect(GridInAppWebViewPage.pendingTargetUrl, isNull);
    });
  });
}
