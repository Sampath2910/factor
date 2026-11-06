import 'dart:convert';
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

    test(
        'resolveMimeType resolves correct MIME types for all supported extensions',
        () {
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
        equals(
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
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
      final dir =
          await CircleConnectFileService.instance.getDocumentsDirectory();
      expect(dir.existsSync(), isTrue);
      expect(dir.path.endsWith('Media/Documents'), isTrue);
    });

    test('getCachedFile returns false when file has not been downloaded',
        () async {
      final result = await CircleConnectFileService.instance.getCachedFile(
        remoteUrl: 'https://efactor.tech/uploads/non_existent.pdf',
        fileName: 'non_existent.pdf',
      );
      expect(result['isCached'], isFalse);
      expect(result['localPath'], isNull);
    });

    test('getCachedFile returns true when file exists in documents directory',
        () async {
      final dir =
          await CircleConnectFileService.instance.getDocumentsDirectory();
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
      expect(emittedEvents['fileDownloadCancelled']?['downloadId'],
          equals('test_dl_999'));

      // Clean up
      CircleConnectFileService.instance.onBridgeEvent = null;
    });

    test('resolveMimeType resolves PowerPoint, Excel, and archive extensions',
        () {
      expect(CircleConnectFileService.resolveMimeType('presentation.ppt'),
          equals('application/vnd.ms-powerpoint'));
      expect(
          CircleConnectFileService.resolveMimeType('presentation.pptx'),
          equals(
              'application/vnd.openxmlformats-officedocument.presentationml.presentation'));
      expect(CircleConnectFileService.resolveMimeType('sheet.xls'),
          equals('application/vnd.ms-excel'));
      expect(
          CircleConnectFileService.resolveMimeType('sheet.xlsx'),
          equals(
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'));
      expect(CircleConnectFileService.resolveMimeType('archive.zip'),
          equals('application/zip'));
      expect(CircleConnectFileService.resolveMimeType('notes.txt'),
          equals('text/plain'));
    });

    test('openFile handles non-existent file cleanly with error result',
        () async {
      final result = await CircleConnectFileService.instance.openFile(
        localPath: '/tmp/non_existent_file_path.pdf',
        fileName: 'non_existent_file_path.pdf',
      );
      expect(result['success'], isFalse);
      expect(result['error'], contains('does not exist'));
    });

    test(
        'openFile dispatches native tech.efactor/circle_connect openFile method',
        () async {
      String? invokedMethod;
      dynamic invokedArguments;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('tech.efactor/circle_connect'),
        (call) async {
          invokedMethod = call.method;
          invokedArguments = call.arguments;
          if (call.method == 'openFile') {
            return <String, dynamic>{'success': true, 'type': 'done'};
          }
          return null;
        },
      );

      final tempDir = Directory.systemTemp.createTempSync('cc_test_');
      final testFile = File('${tempDir.path}/test_doc.pdf')
        ..writeAsBytesSync(utf8.encode('PDF TEST CONTENT'));

      final result = await CircleConnectFileService.instance.openFile(
        localPath: testFile.path,
        fileName: 'test_doc.pdf',
        mimeType: 'application/pdf',
      );

      if (Platform.isAndroid) {
        expect(invokedMethod, equals('openFile'));
        expect(invokedArguments['filePath'], equals(testFile.path));
        expect(invokedArguments['mimeType'], equals('application/pdf'));
        expect(result['success'], isTrue);
      }

      tempDir.deleteSync(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('tech.efactor/circle_connect'),
        null,
      );
    });
  });
}
