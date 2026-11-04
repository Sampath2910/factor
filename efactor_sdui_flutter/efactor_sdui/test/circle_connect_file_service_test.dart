import 'dart:io';

import 'package:efactor_sdui/grid_sdui/circle_connect_file_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return Directory.systemTemp.path;
      },
    );
  });

  group('Circle Connect File Service Contract & Logic Tests', () {
    test('Allowed extensions match Circle Connect requirements', () {
      const requiredExtensions = [
        'pdf',
        'doc',
        'docx',
        'txt',
        'jpg',
        'jpeg',
        'png',
        'zip',
      ];
      for (final ext in requiredExtensions) {
        expect(
          CircleConnectFileService.kAllowedExtensions.contains(ext),
          isTrue,
          reason: 'Extension $ext must be allowed',
        );
      }
    });

    test('Maximum document size is strictly 100 MB', () {
      expect(
        CircleConnectFileService.kMaxDocumentSizeBytes,
        equals(104857600), // 100 * 1024 * 1024
      );
    });

    test('resolveMimeType resolves correct MIME types for all supported extensions', () {
      expect(
        CircleConnectFileService.resolveMimeType('test.pdf'),
        equals('application/pdf'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('test.doc'),
        equals('application/msword'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('test.docx'),
        equals('application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('test.txt'),
        equals('text/plain'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('photo.jpg'),
        equals('image/jpeg'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('photo.jpeg'),
        equals('image/jpeg'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('image.png'),
        equals('image/png'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('archive.zip'),
        equals('application/zip'),
      );
      expect(
        CircleConnectFileService.resolveMimeType('unknown.xyz'),
        equals('application/octet-stream'),
      );
    });

    test('getDocumentsDirectory creates and targets Media/Documents', () async {
      final dir = await CircleConnectFileService.instance.getDocumentsDirectory();
      expect(dir.existsSync(), isTrue);
      expect(dir.path.endsWith('Media/Documents'), isTrue);
    });

    test('getCachedFile returns false when file has not been downloaded', () async {
      final result = await CircleConnectFileService.instance.getCachedFile(
        remoteUrl: 'https://efactor.tech/uploads/non_existent.pdf',
        fileName: 'non_existent.pdf',
      );
      expect(result['isCached'], isFalse);
      expect(result['localPath'], isNull);
    });

    test('getCachedFile returns true when file exists in documents directory', () async {
      final dir = await CircleConnectFileService.instance.getDocumentsDirectory();
      final testFile = File('${dir.path}/test_cached_doc.pdf');
      await testFile.writeAsString('Dummy PDF content');

      final result = await CircleConnectFileService.instance.getCachedFile(
        remoteUrl: 'https://efactor.tech/uploads/test_cached_doc.pdf',
        fileName: 'test_cached_doc.pdf',
      );

      expect(result['isCached'], isTrue);
      expect(result['localPath'], equals(testFile.path));
      expect(result['size'], equals(testFile.lengthSync()));

      // Clean up
      if (testFile.existsSync()) {
        testFile.deleteSync();
      }
    });

    test('Events emit to onBridgeEvent with correct payload structures', () {
      final emittedEvents = <String, Map<String, dynamic>>{};
      CircleConnectFileService.instance.onBridgeEvent = (event, data) {
        emittedEvents[event] = data;
      };

      // Cancel non-existent download triggers cancelled event
      CircleConnectFileService.instance.cancelDownload('test_dl_999');

      expect(emittedEvents.containsKey('fileDownloadCancelled'), isTrue);
      expect(emittedEvents['fileDownloadCancelled']?['downloadId'], equals('test_dl_999'));

      // Clean up
      CircleConnectFileService.instance.onBridgeEvent = null;
    });
  });
}
