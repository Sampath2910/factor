import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/services/push_notification_bootstrap.dart';

/// Pure-logic tests for the iOS notification-tap redirect fix. The native
/// bridge (AppDelegate/SceneDelegate) and the live routing side effects are
/// verified on a physical device; here we lock down the decidable logic that
/// the fix introduced: relative-URL normalization, duplicate-tap keying, host
/// validation, and Professional Space vs Circle Connect classification.
void main() {
  group('normalizeRelativeNotificationUrls', () {
    test('rewrites a relative target_url to absolute efactor.tech', () {
      final data = <String, dynamic>{'target_url': '/grid/events/42'};
      normalizeRelativeNotificationUrls(data);
      expect(data['target_url'], 'https://efactor.tech/grid/events/42');
    });

    test('rewrites url and targetUrl variants too', () {
      final data = <String, dynamic>{
        'url': '/a',
        'targetUrl': '/b',
      };
      normalizeRelativeNotificationUrls(data);
      expect(data['url'], 'https://efactor.tech/a');
      expect(data['targetUrl'], 'https://efactor.tech/b');
    });

    test('leaves an already-absolute url unchanged', () {
      final data = <String, dynamic>{
        'target_url': 'https://efactor.tech/grid/events/42',
      };
      normalizeRelativeNotificationUrls(data);
      expect(data['target_url'], 'https://efactor.tech/grid/events/42');
    });

    test('normalized relative url passes isSafeEfactorUrl', () {
      final data = <String, dynamic>{'target_url': '/grid/events/42'};
      expect(isSafeEfactorUrl(data['target_url'].toString()), isFalse);
      normalizeRelativeNotificationUrls(data);
      expect(isSafeEfactorUrl(data['target_url'].toString()), isTrue);
    });
  });

  group('notificationTapDedupKey', () {
    test('same FCM message id produces the same key (dedup across sources)', () {
      final a = <String, dynamic>{'_fcm_message_id': 'abc123'};
      final b = <String, dynamic>{'gcm.message_id': 'abc123'};
      expect(notificationTapDedupKey(a), notificationTapDedupKey(b));
      expect(notificationTapDedupKey(a), isNotEmpty);
    });

    test('conversation + message + action compose the key', () {
      final data = <String, dynamic>{
        'conversation_id': 'c1',
        'message_id': 'm1',
        'actionId': 'reply',
      };
      expect(notificationTapDedupKey(data), 'c1|m1|reply');
    });

    test('different taps produce different keys', () {
      final a = <String, dynamic>{'conversation_id': 'c1', 'message_id': 'm1'};
      final b = <String, dynamic>{'conversation_id': 'c1', 'message_id': 'm2'};
      expect(notificationTapDedupKey(a) == notificationTapDedupKey(b), isFalse);
    });

    test('empty when nothing identifying is present', () {
      expect(notificationTapDedupKey(<String, dynamic>{'type': 'ACTIVITY'}), '');
    });
  });

  group('isSafeEfactorUrl', () {
    test('accepts efactor.tech and subdomains', () {
      expect(isSafeEfactorUrl('https://efactor.tech/x'), isTrue);
      expect(isSafeEfactorUrl('https://app.efactor.tech/x'), isTrue);
    });

    test('rejects relative and foreign hosts', () {
      expect(isSafeEfactorUrl('/grid/events/42'), isFalse);
      expect(isSafeEfactorUrl('https://evil.example.com/x'), isFalse);
      expect(isSafeEfactorUrl(''), isFalse);
    });
  });

  group('isProfessionalSpacePush', () {
    test('true for an explicit professional space event', () {
      expect(
        isProfessionalSpacePush(<String, dynamic>{'type': 'PROFESSIONAL_SPACE_EVENT'}),
        isTrue,
      );
    });

    test('true for a /grid (non chat) target_url', () {
      expect(
        isProfessionalSpacePush(<String, dynamic>{'target_url': '/grid/events/42'}),
        isTrue,
      );
    });

    test('false for a /grid-chat target_url (that is Circle Connect)', () {
      expect(
        isProfessionalSpacePush(<String, dynamic>{'target_url': '/grid-chat/conversation/9'}),
        isFalse,
      );
    });
  });
}
