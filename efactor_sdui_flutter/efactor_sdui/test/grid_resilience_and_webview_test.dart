import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:efactor_sdui/grid_sdui/grid_in_app_webview_page.dart';
import 'package:efactor_sdui/grid_sdui/grid_schema_repository.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Populate the asset bundle mock for 'assets/branding/grid.json' from local disk
    final assetFile = File('assets/branding/grid.json');
    if (assetFile.existsSync()) {
      final jsonContent = assetFile.readAsStringSync();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (ByteData? message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        if (key == 'assets/branding/grid.json') {
          return ByteData.view(Uint8List.fromList(utf8.encode(jsonContent)).buffer);
        }
        return null;
      });
    }
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  group('Grid SDUI Asset Fallback and Cold-Start Resilience', () {
    test('readFromCache returns valid bundled asset schema when disk cache is empty', () async {
      await GridSchemaRepository.clearUserCache(userId: 99999);
      final repo = GridSchemaRepository(
        accessToken: 'test_token',
        userId: 99999,
      );

      final schema = await repo.readFromCache();
      expect(schema, isNotNull);
      expect(schema!['schemaVersion'] ?? schema['schema_version'], isNotNull);
      expect(schema['components'], isA<Map>());
      expect(schema['page'], isA<Map>());
      expect(schema['_clientGridSchemaSource'], contains('asset://assets/branding/grid.json'));
      expect(schema['_clientGridSchemaCacheHit'], isTrue);
    });

    test('load() gracefully falls back to asset bundle when network fails and no disk cache', () async {
      await GridSchemaRepository.clearUserCache(userId: 99998);

      final failingClient = MockClient((request) async {
        throw const SocketException('Network is unreachable');
      });

      final repo = GridSchemaRepository(
        accessToken: 'test_token',
        userId: 99998,
        client: failingClient,
      );

      final schema = await repo.load();
      expect(schema, isNotNull);
      expect(schema['components'], isA<Map>());
      expect(schema['_clientGridSchemaSource'], contains('asset://assets/branding/grid.json'));
    });
  });

  group('Grid URL Sanitization in GridSduiState', () {
    test('GridSduiState normalizes duplicate /index.php/index.php/ prefixes', () async {
      final schemaFile = File('assets/branding/grid.json');
      final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final state = GridSduiState(schema);

      Uri? openedUri;
      state.inAppWebViewOpener = (Uri uri, {String? title}) async {
        openedUri = uri;
        return true;
      };

      await state.dispatch(
        'grid-open-professional-space',
        extra: <String, dynamic>{
          'url': 'https://efactor.tech/index.php/index.php/grid?grid_sso=token123',
        },
      );

      expect(openedUri, isNotNull);
      expect(openedUri.toString(), 'https://efactor.tech/index.php/grid?grid_sso=token123');
      expect(openedUri.toString().contains('/index.php/index.php/'), isFalse);
    });

    test('GridSduiState handles deeply nested duplicate /index.php/index.php/index.php/', () async {
      final schemaFile = File('assets/branding/grid.json');
      final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final state = GridSduiState(schema);

      Uri? openedUri;
      state.inAppWebViewOpener = (Uri uri, {String? title}) async {
        openedUri = uri;
        return true;
      };

      await state.dispatch(
        'grid-open-professional-space',
        extra: <String, dynamic>{
          'url': 'https://efactor.tech/index.php/index.php/index.php/grid-chat',
        },
      );

      expect(openedUri, isNotNull);
      expect(openedUri.toString(), 'https://efactor.tech/index.php/grid-chat');
    });
  });

  group('Grid In-App WebView Navigation Scheme & SSO Logic', () {
    test('isExternalScheme identifies WhatsApp, phone, email, and intent schemes', () {
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('whatsapp://send?phone=919876543210')), isTrue);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('https://wa.me/919876543210')), isTrue);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('https://api.whatsapp.com/send?phone=919876543210')), isTrue);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('tel:+919876543210')), isTrue);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('mailto:support@efactor.tech')), isTrue);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('sms:+919876543210')), isTrue);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('intent://view?data=abc')), isTrue);

      // Normal in-app web browsing routes should not be classified as external
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('https://efactor.tech/index.php/grid')), isFalse);
      expect(GridInAppWebViewPage.isExternalScheme(Uri.parse('https://efactor.tech/index.php/grid-chat')), isFalse);
    });

    test('normalizeUrl and normalizeUri strip repeated index.php path fragments', () {
      expect(
        GridInAppWebViewPage.normalizeUrl('https://efactor.tech/index.php/index.php/grid'),
        'https://efactor.tech/index.php/grid',
      );
      expect(
        GridInAppWebViewPage.normalizeUrl('https://efactor.tech/index.php/index.php/index.php/grid-chat?tab=1'),
        'https://efactor.tech/index.php/grid-chat?tab=1',
      );

      final uri = GridInAppWebViewPage.normalizeUri(
        Uri.parse('https://efactor.tech/index.php/index.php/grid?grid_sso=abc'),
      );
      expect(uri.path, '/index.php/grid');
      expect(uri.queryParameters['grid_sso'], 'abc');
    });

    test('shouldInjectSso and injectSso preserve grid_sso on server /signin redirects', () {
      final initialUri = Uri.parse('https://efactor.tech/index.php/grid?grid_sso=sso_token_secure_99');
      final signinRedirect = Uri.parse('https://efactor.tech/index.php/signin');

      expect(GridInAppWebViewPage.shouldInjectSso(signinRedirect, initialUri: initialUri), isTrue);

      final injected = GridInAppWebViewPage.injectSso(signinRedirect, initialUri: initialUri);
      expect(injected.queryParameters['grid_sso'], 'sso_token_secure_99');
      expect(injected.toString(), 'https://efactor.tech/index.php/signin?grid_sso=sso_token_secure_99');

      // If target already has grid_sso, do not re-inject
      final alreadyHasSso = Uri.parse('https://efactor.tech/index.php/signin?grid_sso=existing');
      expect(GridInAppWebViewPage.shouldInjectSso(alreadyHasSso, initialUri: initialUri), isFalse);

      // If initialUri did not have grid_sso, do not inject
      final initialWithoutSso = Uri.parse('https://efactor.tech/index.php/grid');
      expect(GridInAppWebViewPage.shouldInjectSso(signinRedirect, initialUri: initialWithoutSso), isFalse);
    });

    test('GridInAppWebViewPage defaults to showAppBar: false (header hidden for full-screen)', () {
      final page = GridInAppWebViewPage(
        uri: Uri.parse('https://efactor.tech/index.php/grid'),
        title: 'Professional Space',
      );
      expect(page.showAppBar, isFalse);
    });

    test('GridInAppWebViewPage preserves explicit showAppBar: true when specified', () {
      final page = GridInAppWebViewPage(
        uri: Uri.parse('https://efactor.tech/index.php/grid'),
        title: 'Professional Space',
        showAppBar: true,
      );
      expect(page.showAppBar, isTrue);
    });

    testWidgets('GridInAppWebViewPage does not save snapshots and initializes in live-only mode', (WidgetTester tester) async {
      final page = GridInAppWebViewPage(
        uri: Uri.parse('https://efactor.tech/index.php/grid'),
        title: 'Professional Space',
      );
      expect(page.uri.toString(), 'https://efactor.tech/index.php/grid');
      expect(page.title, 'Professional Space');
      expect(page.showAppBar, isFalse);
    });

    test('isIgnorableError correctly distinguishes benign redirect aborts from actual offline errors', () {
      // Benign redirect / cancellation aborts must return true (ignored)
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -3,
          description: 'net::ERR_ABORTED',
        ),
        isTrue,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -999,
          description: 'NSURLErrorCancelled',
        ),
        isTrue,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: 0,
          description: 'The request was canceled',
        ),
        isTrue,
      );

      // Real network errors must return false (trigger offline UI)
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -106,
          description: 'net::ERR_INTERNET_DISCONNECTED',
        ),
        isFalse,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -105,
          description: 'net::ERR_NAME_NOT_RESOLVED',
        ),
        isFalse,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -118,
          description: 'net::ERR_CONNECTION_TIMED_OUT',
        ),
        isFalse,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -102,
          description: 'net::ERR_CONNECTION_REFUSED',
        ),
        isFalse,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -1009,
          description: 'The Internet connection appears to be offline.',
        ),
        isFalse,
      );
      expect(
        GridInAppWebViewPage.isIgnorableError(
          errorCode: -1001,
          description: 'The request timed out.',
        ),
        isFalse,
      );
    });
  });

  group('Grid SSO Token Extraction & Navigation Resolution', () {
    test('extractSsoToken accurately extracts token from content, actions, and components', () {
      final mockLiveSchema = <String, dynamic>{
        'content': <String, dynamic>{
          'featureCards': <dynamic>[
            <String, dynamic>{
              'id': 'professional-space',
              'url': 'https://efactor.tech/index.php/grid?grid_sso=token_live_12345',
            },
          ],
        },
        'schema': <String, dynamic>{
          'actions': <String, dynamic>{
            'grid-open-professional-space': <String, dynamic>{
              'url': 'https://efactor.tech/index.php/grid?grid_sso=token_live_12345',
            },
          },
        },
      };

      expect(GridSchemaRepository.extractSsoToken(mockLiveSchema), 'token_live_12345');
      expect(GridSchemaRepository.extractSsoToken(<String, dynamic>{'grid_sso': 'token_direct'}), 'token_direct');
      expect(GridSchemaRepository.extractSsoToken(<String, dynamic>{}), isNull);
    });

    test('resolveAuthenticatedUri attaches grid_sso to bare Grid and Circle Connect URLs', () async {
      final repo = GridSchemaRepository(
        accessToken: 'test_token',
        userId: 707,
      );

      final mockLiveSchema = <String, dynamic>{
        'content': <String, dynamic>{
          'featureCards': <dynamic>[
            <String, dynamic>{
              'id': 'professional-space',
              'url': 'https://efactor.tech/index.php/grid?grid_sso=auth_token_abc',
            },
          ],
        },
      };

      final bareProfUri = Uri.parse('https://efactor.tech/index.php/grid');
      final resolvedProf = await repo.resolveAuthenticatedUri(bareProfUri, activeSchema: mockLiveSchema);
      expect(resolvedProf.queryParameters['grid_sso'], 'auth_token_abc');
      expect(resolvedProf.path, '/index.php/grid');

      final bareChatUri = Uri.parse('https://efactor.tech/index.php/grid-chat');
      final resolvedChat = await repo.resolveAuthenticatedUri(bareChatUri, activeSchema: mockLiveSchema);
      expect(resolvedChat.queryParameters['grid_sso'], 'auth_token_abc');
      expect(resolvedChat.path, '/index.php/grid-chat');

      // External URLs must remain untouched
      final extUri = Uri.parse('https://google.com/search');
      final resolvedExt = await repo.resolveAuthenticatedUri(extUri, activeSchema: mockLiveSchema);
      expect(resolvedExt.queryParameters.containsKey('grid_sso'), isFalse);
    });

    test('GridSduiState prefers action URL with grid_sso over bare extra url', () async {
      final schemaFile = File('assets/branding/grid.json');
      final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final state = GridSduiState(schema);

      Uri? openedUri;
      state.inAppWebViewOpener = (Uri uri, {String? title}) async {
        openedUri = uri;
        return true;
      };

      // When extra provides a bare URL but action or destination has an SSO token
      await state.dispatch(
        'grid-open-professional-space',
        extra: <String, dynamic>{
          'url': 'https://efactor.tech/index.php/grid?grid_sso=signed_token_999',
        },
      );

      expect(openedUri, isNotNull);
      expect(openedUri!.queryParameters['grid_sso'], 'signed_token_999');
    });
  });
}
