import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Production-ready native file sharing, document caching, and "Open With"
/// service for Circle Connect (GRID Chat).
class CircleConnectFileService {
  CircleConnectFileService._();
  static final CircleConnectFileService instance = CircleConnectFileService._();

  static const int kMaxDocumentSizeBytes = 100 * 1024 * 1024; // 100 MB
  static const List<String> kAllowedExtensions = <String>[
    'pdf',
    'ppt',
    'pptx',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'txt',
    'csv',
    'rtf',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'zip',
  ];

  final Map<String, http.Client> _activeDownloads = <String, http.Client>{};
  final Map<String, http.Client> _activeUploads = <String, http.Client>{};

  /// Dispatches progress/completion events to JavaScript via registered callbacks.
  void Function(String eventName, Map<String, dynamic> data)? onBridgeEvent;

  void _emitEvent(String eventName, Map<String, dynamic> data) {
    if (onBridgeEvent != null) {
      try {
        onBridgeEvent!(eventName, data);
      } catch (e) {
        debugPrint('[CircleConnectFiles] emitEvent error: $e');
      }
    }
  }

  /// Resolves the MIME type for common document and media extensions.
  static String resolveMimeType(String fileNameOrExt) {
    final lower = fileNameOrExt.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : lower;
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'rtf':
        return 'application/rtf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'zip':
        return 'application/zip';
      case 'rar':
        return 'application/x-rar-compressed';
      case '7z':
        return 'application/x-7z-compressed';
      default:
        return 'application/octet-stream';
    }
  }

  /// Resolves the storage directory for downloaded documents.
  /// Android: Android/media/<application-package>/Media/Documents/
  /// iOS: <ApplicationSupportDirectory>/Media/Documents/
  Future<Directory> getDocumentsDirectory() async {
    if (Platform.isAndroid) {
      try {
        final extDirs = await getExternalStorageDirectories(
          type: StorageDirectory.documents,
        );
        if (extDirs != null && extDirs.isNotEmpty) {
          final dataPath = extDirs.first.path;
          // Converts /Android/data/<package>/files/documents to /Android/media/<package>/Media/Documents
          // Case-insensitively removes /files/documents or /files so no duplicate /documents directory is created.
          final mediaPath = dataPath
              .replaceFirst('/Android/data/', '/Android/media/')
              .replaceAll(RegExp(r'/files(/documents)?', caseSensitive: false),
                  '/Media/Documents');
          final dir = Directory(mediaPath);
          if (!dir.existsSync()) {
            dir.createSync(recursive: true);
          }
          return dir;
        }
      } catch (e) {
        debugPrint(
            '[CircleConnectFiles] getExternalStorageDirectories error: $e');
      }
      final appDoc = await getApplicationDocumentsDirectory();
      final fallbackDir = Directory('${appDoc.path}/Media/Documents');
      if (!fallbackDir.existsSync()) {
        fallbackDir.createSync(recursive: true);
      }
      return fallbackDir;
    } else {
      // iOS: Save directly to the App Documents directory so files are accessible to the user
      // in the Files app under "On My iPhone -> Efactor IoE"
      // (UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace in Info.plist expose this).
      final appDoc = await getApplicationDocumentsDirectory();
      if (!appDoc.existsSync()) {
        appDoc.createSync(recursive: true);
      }
      return appDoc;
    }
  }

  /// Picks a document from the native file chooser.
  /// Files selected through "Document" are 100% uncompressed byte-for-byte.
  Future<Map<String, dynamic>> pickDocument({
    List<String>? allowedExtensions,
    int? maxSizeBytes,
  }) async {
    final extensions = allowedExtensions != null && allowedExtensions.isNotEmpty
        ? allowedExtensions
            .map((e) => e.replaceAll('.', '').toLowerCase())
            .toList()
        : kAllowedExtensions;
    final limit = maxSizeBytes ?? kMaxDocumentSizeBytes;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return <String, dynamic>{
          'success': false,
          'cancelled': true,
          'error': null,
        };
      }

      final platformFile = result.files.first;
      final path = platformFile.path;
      if (path == null || path.isEmpty) {
        return <String, dynamic>{
          'success': false,
          'error': 'File path is unavailable.',
        };
      }

      final file = File(path);
      if (!file.existsSync()) {
        return <String, dynamic>{
          'success': false,
          'error': 'Selected file does not exist on disk.',
        };
      }

      final size = file.lengthSync();
      if (size > limit) {
        final mb = (size / (1024 * 1024)).toStringAsFixed(1);
        final maxMb = (limit / (1024 * 1024)).toStringAsFixed(0);
        return <String, dynamic>{
          'success': false,
          'error': 'File size ($mb MB) exceeds maximum limit of $maxMb MB.',
        };
      }

      final ext = platformFile.extension ??
          (path.contains('.') ? path.split('.').last.toLowerCase() : '');
      final mimeType = resolveMimeType(ext);

      return <String, dynamic>{
        'success': true,
        'file': <String, dynamic>{
          'name': platformFile.name,
          'path': path,
          'size': size,
          'extension': ext,
          'mimeType': mimeType,
        },
      };
    } catch (e) {
      debugPrint('[CircleConnectFiles] pickDocument error: $e');
      return <String, dynamic>{
        'success': false,
        'error': 'Failed to pick document: $e',
      };
    }
  }

  /// Sanitizes a file name for safe filesystem storage.
  String _sanitizeFileName(String rawName, String fallbackExt) {
    var clean = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (clean.isEmpty) {
      clean = 'document_${DateTime.now().millisecondsSinceEpoch}.$fallbackExt';
    }
    return clean;
  }

  /// Checks if a remote file has already been downloaded and cached locally.
  Future<Map<String, dynamic>> getCachedFile({
    required String remoteUrl,
    String? fileName,
    String? mimeType,
  }) async {
    final cleanUrl = remoteUrl.trim();
    if (cleanUrl.isEmpty) {
      return <String, dynamic>{'isCached': false, 'localPath': null};
    }

    try {
      final docDir = await getDocumentsDirectory();
      final effectiveName = (fileName != null && fileName.trim().isNotEmpty)
          ? _sanitizeFileName(fileName, 'dat')
          : _sanitizeFileName(
              cleanUrl.split('/').last.split('?').first,
              'dat',
            );

      final candidate = File('${docDir.path}/$effectiveName');
      if (candidate.existsSync() && candidate.lengthSync() > 0) {
        return <String, dynamic>{
          'isCached': true,
          'localPath': candidate.path,
          'fileName': effectiveName,
          'size': candidate.lengthSync(),
        };
      }

      // Also check hashed URL filename to handle query-string variations
      final hashName =
          '${cleanUrl.hashCode.abs().toRadixString(16)}_$effectiveName';
      final hashCandidate = File('${docDir.path}/$hashName');
      if (hashCandidate.existsSync() && hashCandidate.lengthSync() > 0) {
        return <String, dynamic>{
          'isCached': true,
          'localPath': hashCandidate.path,
          'fileName': hashName,
          'size': hashCandidate.lengthSync(),
        };
      }

      // On iOS, also check legacy subdirectories so previously downloaded files remain cached
      if (Platform.isIOS) {
        try {
          // Check previous nested Documents/Documents path
          final nestedDir = Directory('${docDir.path}/Documents');
          final nestedCandidate = File('${nestedDir.path}/$effectiveName');
          if (nestedCandidate.existsSync() && nestedCandidate.lengthSync() > 0) {
            try {
              nestedCandidate.copySync(candidate.path);
              return <String, dynamic>{
                'isCached': true,
                'localPath': candidate.path,
                'fileName': effectiveName,
                'size': candidate.lengthSync(),
              };
            } catch (_) {
              return <String, dynamic>{
                'isCached': true,
                'localPath': nestedCandidate.path,
                'fileName': effectiveName,
                'size': nestedCandidate.lengthSync(),
              };
            }
          }

          final appSupport = await getApplicationSupportDirectory();
          final legacyDir = Directory('${appSupport.path}/Media/Documents');
          final legacyCandidate = File('${legacyDir.path}/$effectiveName');
          if (legacyCandidate.existsSync() && legacyCandidate.lengthSync() > 0) {
            try {
              legacyCandidate.copySync(candidate.path);
              return <String, dynamic>{
                'isCached': true,
                'localPath': candidate.path,
                'fileName': effectiveName,
                'size': candidate.lengthSync(),
              };
            } catch (_) {
              return <String, dynamic>{
                'isCached': true,
                'localPath': legacyCandidate.path,
                'fileName': effectiveName,
                'size': legacyCandidate.lengthSync(),
              };
            }
          }
          final legacyHashCandidate = File('${legacyDir.path}/$hashName');
          if (legacyHashCandidate.existsSync() &&
              legacyHashCandidate.lengthSync() > 0) {
            return <String, dynamic>{
              'isCached': true,
              'localPath': legacyHashCandidate.path,
              'fileName': hashName,
              'size': legacyHashCandidate.lengthSync(),
            };
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[CircleConnectFiles] getCachedFile error: $e');
    }

    return <String, dynamic>{'isCached': false, 'localPath': null};
  }

  /// Downloads a file with real-time progress, cancellation, and local storage.
  Future<Map<String, dynamic>> downloadFile({
    required String remoteUrl,
    required String downloadId,
    String? fileName,
    String? mimeType,
    Map<String, String>? headers,
  }) async {
    final cleanUrl = remoteUrl.trim();
    if (cleanUrl.isEmpty) {
      const err = 'Remote URL cannot be empty.';
      _emitEvent('fileDownloadFailed', {
        'downloadId': downloadId,
        'fileName': fileName ?? '',
        'error': err,
      });
      return <String, dynamic>{'success': false, 'error': err};
    }

    // Check cache first
    final cached = await getCachedFile(
      remoteUrl: cleanUrl,
      fileName: fileName,
      mimeType: mimeType,
    );
    if (cached['isCached'] == true) {
      final path = cached['localPath'] as String;
      final cachedSize = (cached['size'] as int?) ?? File(path).lengthSync();
      final effectiveName = (cached['fileName'] as String?) ??
          (fileName != null && fileName.trim().isNotEmpty
              ? _sanitizeFileName(fileName, 'dat')
              : path.split('/').last);

      _emitEvent('fileDownloadProgress', {
        'downloadId': downloadId,
        'fileName': effectiveName,
        'bytesReceived': cachedSize,
        'totalBytes': cachedSize,
        'progress': 100.0,
      });
      _emitEvent('fileDownloadCompleted', {
        'downloadId': downloadId,
        'fileName': effectiveName,
        'localPath': path,
        'size': cachedSize,
      });
      return <String, dynamic>{
        'success': true,
        'downloadId': downloadId,
        'localPath': path,
        'fileName': effectiveName,
        'size': cachedSize,
        'cached': true,
      };
    }

    final client = http.Client();
    _activeDownloads[downloadId] = client;

    try {
      final docDir = await getDocumentsDirectory();
      final effectiveName = (fileName != null && fileName.trim().isNotEmpty)
          ? _sanitizeFileName(fileName, 'dat')
          : _sanitizeFileName(
              cleanUrl.split('/').last.split('?').first,
              'dat',
            );
      final targetFile = File('${docDir.path}/$effectiveName');
      final tempFile = File('${docDir.path}/$effectiveName.tmp');
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }

      final request = http.Request('GET', Uri.parse(cleanUrl));
      if (headers != null) {
        request.headers.addAll(headers);
      }

      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final err = 'Download failed with status ${response.statusCode}.';
        _emitEvent('fileDownloadFailed', {
          'downloadId': downloadId,
          'fileName': effectiveName,
          'error': err,
        });
        return <String, dynamic>{'success': false, 'error': err};
      }

      final totalBytes = response.contentLength ?? 0;
      if (totalBytes > kMaxDocumentSizeBytes) {
        const err = 'File size exceeds maximum limit of 100 MB.';
        _emitEvent('fileDownloadFailed', {
          'downloadId': downloadId,
          'fileName': effectiveName,
          'error': err,
        });
        return <String, dynamic>{'success': false, 'error': err};
      }

      var receivedBytes = 0;
      final sink = tempFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          final progress =
              ((receivedBytes / totalBytes) * 100).clamp(0.0, 100.0);
          _emitEvent('fileDownloadProgress', {
            'downloadId': downloadId,
            'fileName': effectiveName,
            'bytesReceived': receivedBytes,
            'totalBytes': totalBytes,
            'progress': double.parse(progress.toStringAsFixed(1)),
          });
        }
      }

      await sink.flush();
      await sink.close();

      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      tempFile.renameSync(targetFile.path);

      _emitEvent('fileDownloadCompleted', {
        'downloadId': downloadId,
        'fileName': effectiveName,
        'localPath': targetFile.path,
        'size': receivedBytes,
      });

      return <String, dynamic>{
        'success': true,
        'downloadId': downloadId,
        'localPath': targetFile.path,
        'fileName': effectiveName,
        'size': receivedBytes,
      };
    } catch (e) {
      if (e is http.ClientException &&
          e.message.contains('Connection closed')) {
        // Cancelled by user
        _emitEvent('fileDownloadCancelled', {
          'downloadId': downloadId,
          'fileName': fileName ?? '',
        });
        return <String, dynamic>{
          'success': false,
          'cancelled': true,
          'error': 'Download cancelled.',
        };
      }
      final err = 'Download failed: $e';
      _emitEvent('fileDownloadFailed', {
        'downloadId': downloadId,
        'fileName': fileName ?? '',
        'error': err,
      });
      return <String, dynamic>{'success': false, 'error': err};
    } finally {
      _activeDownloads.remove(downloadId);
      client.close();
    }
  }

  /// Cancels an in-progress download.
  void cancelDownload(String downloadId) {
    final client = _activeDownloads.remove(downloadId);
    if (client != null) {
      try {
        client.close();
      } catch (_) {}
    }
    _emitEvent('fileDownloadCancelled', {'downloadId': downloadId});
  }

  /// Opens a downloaded file using native platform capabilities:
  /// Android: `OpenFilex.open` with FileProvider and correct MIME type.
  /// iOS: `Share.shareXFiles` (AirDrop, Open In, Save to Files).
  Future<Map<String, dynamic>> openFile({
    required String localPath,
    String? mimeType,
    String? fileName,
  }) async {
    final cleanPath = localPath.trim();
    if (cleanPath.isEmpty) {
      return <String, dynamic>{
        'success': false,
        'error': 'File path is empty.',
      };
    }

    final file = File(cleanPath);
    if (!file.existsSync()) {
      return <String, dynamic>{
        'success': false,
        'error': 'File does not exist at path: $cleanPath',
      };
    }

    final effectiveMime = (mimeType != null && mimeType.trim().isNotEmpty)
        ? mimeType.trim()
        : resolveMimeType(cleanPath);

    try {
      if (Platform.isAndroid) {
        debugPrint(
          '[CircleConnectFiles] openFile: path=$cleanPath, mime=$effectiveMime, exists=${file.existsSync()}',
        );
        // 1. Primary path: Native FileProvider via platform channel (100% permission-free on SDK 36/Android 16)
        try {
          const channel = MethodChannel('tech.efactor/circle_connect');
          final nativeResult = await channel.invokeMethod<Map>('openFile', {
            'filePath': cleanPath,
            'mimeType': effectiveMime,
          });
          if (nativeResult != null && nativeResult['success'] == true) {
            return <String, dynamic>{
              'success': true,
              'message': 'done',
              'type': 'done',
              'localPath': cleanPath,
              'mimeType': effectiveMime,
            };
          }
        } catch (e) {
          debugPrint('[CircleConnectFiles] native openFile error: $e');
        }

        // 2. Secondary fallback
        final result = await OpenFilex.open(
          cleanPath,
          type: effectiveMime,
        );
        debugPrint(
          '[CircleConnectFiles] OpenFilex.open result: type=${result.type} message=${result.message}',
        );
        final isSuccess = result.type == ResultType.done;
        return <String, dynamic>{
          'success': isSuccess,
          'message': result.message,
          'type': result.type.name,
          'localPath': cleanPath,
          'mimeType': effectiveMime,
        };
      } else {
        // iOS: Native QuickLook in-app preview via UIDocumentInteractionController (PDF, Word, Excel, PPT, ZIP, etc.)
        try {
          const channel = MethodChannel('tech.efactor/circle_connect');
          final nativeResult = await channel.invokeMethod<Map>('openFile', {
            'filePath': cleanPath,
            'mimeType': effectiveMime,
            'fileName': fileName ?? cleanPath.split('/').last,
          });
          if (nativeResult != null && nativeResult['success'] == true) {
            return <String, dynamic>{
              'success': true,
              'message': 'done',
              'type': nativeResult['type'] ?? 'preview',
              'localPath': cleanPath,
              'mimeType': effectiveMime,
            };
          }
        } catch (e) {
          debugPrint('[CircleConnectFiles] iOS native openFile error: $e');
        }

        // Secondary fallback on iOS: Native Share Sheet
        final xfile = XFile(
          cleanPath,
          mimeType: effectiveMime,
          name: fileName ?? cleanPath.split('/').last,
        );
        final result = await SharePlus.instance.share(
          ShareParams(
            files: <XFile>[xfile],
          ),
        );
        return <String, dynamic>{
          'success': true,
          'status': result.status.name,
        };
      }
    } catch (e) {
      debugPrint('[CircleConnectFiles] openFile error: $e');
      return <String, dynamic>{
        'success': false,
        'error': 'Failed to open file: $e',
      };
    }
  }

  /// Saves a remote document to the device's public Download folder (Android)
  /// or opens the native Share Sheet for "Save to Files" (iOS).
  Future<Map<String, dynamic>> saveFileToDownloads({
    required String remoteUrl,
    String? fileName,
    String? mimeType,
    Map<String, String>? headers,
  }) async {
    final downloadResult = await downloadFile(
      remoteUrl: remoteUrl,
      downloadId: 'save_${DateTime.now().millisecondsSinceEpoch}',
      fileName: fileName,
      mimeType: mimeType,
      headers: headers,
    );

    if (downloadResult['success'] != true) {
      return downloadResult;
    }

    final localPath = downloadResult['localPath'] as String;
    final effectiveName = (fileName != null && fileName.trim().isNotEmpty)
        ? _sanitizeFileName(fileName, 'dat')
        : localPath.split('/').last;
    final effectiveMime = (mimeType != null && mimeType.trim().isNotEmpty)
        ? mimeType.trim()
        : resolveMimeType(effectiveName);

    try {
      const channel = MethodChannel('tech.efactor/circle_connect');
      final res = await channel.invokeMethod<dynamic>('saveFileToDownloads', {
        'filePath': localPath,
        'fileName': effectiveName,
        'mimeType': effectiveMime,
      });
      final isSuccess = res == true || (res is Map && res['success'] == true);
      if (isSuccess) {
        final savedPath = (res is Map && res['localPath'] != null)
            ? res['localPath'].toString()
            : localPath;
        return <String, dynamic>{
          'success': true,
          'fileName': effectiveName,
          'localPath': savedPath,
        };
      }
    } catch (e) {
      debugPrint('[CircleConnectFiles] native saveFileToDownloads error: $e');
    }

    if (Platform.isAndroid) {
      try {
        final downloadDir = Directory('/storage/emulated/0/Download');
        if (downloadDir.existsSync()) {
          final target = File('${downloadDir.path}/$effectiveName');
          File(localPath).copySync(target.path);
          return <String, dynamic>{
            'success': true,
            'path': target.path,
          };
        }
      } catch (e) {
        debugPrint('[CircleConnectFiles] copy to Download error: $e');
      }
      return <String, dynamic>{
        'success': true,
        'path': localPath,
      };
    } else {
      // iOS fallback: Share sheet offers Save to Files
      return openFile(
        localPath: localPath,
        mimeType: mimeType,
        fileName: fileName,
      );
    }
  }

  /// Uploads a document with chunked progress tracking.
  Future<Map<String, dynamic>> uploadFile({
    required String uploadId,
    required String localPath,
    required String uploadUrl,
    Map<String, String>? headers,
    Map<String, String>? fields,
  }) async {
    final file = File(localPath);
    if (!file.existsSync()) {
      const err = 'File to upload does not exist.';
      _emitEvent('fileUploadFailed', {
        'uploadId': uploadId,
        'fileName': localPath.split('/').last,
        'error': err,
      });
      return <String, dynamic>{'success': false, 'error': err};
    }

    final size = file.lengthSync();
    if (size > kMaxDocumentSizeBytes) {
      const err = 'File size exceeds maximum limit of 100 MB.';
      _emitEvent('fileUploadFailed', {
        'uploadId': uploadId,
        'fileName': localPath.split('/').last,
        'error': err,
      });
      return <String, dynamic>{'success': false, 'error': err};
    }

    final client = http.Client();
    _activeUploads[uploadId] = client;

    try {
      final fileName = localPath.split('/').last;
      final uri = Uri.parse(uploadUrl);
      final request = http.MultipartRequest('POST', uri);
      if (headers != null) {
        request.headers.addAll(headers);
      }
      if (fields != null) {
        request.fields.addAll(fields);
      }

      // Streamed file with progress
      var bytesSent = 0;
      final byteStream = file.openRead().transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            bytesSent += chunk.length;
            final progress = ((bytesSent / size) * 100).clamp(0.0, 100.0);
            _emitEvent('fileUploadProgress', {
              'uploadId': uploadId,
              'fileName': fileName,
              'bytesSent': bytesSent,
              'totalBytes': size,
              'progress': double.parse(progress.toStringAsFixed(1)),
            });
            sink.add(chunk);
          },
        ),
      );

      final multipartFile = http.MultipartFile(
        'file',
        byteStream,
        size,
        filename: fileName,
      );
      request.files.add(multipartFile);

      final response = await client.send(request);
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        String? remoteUrl;
        try {
          final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
          remoteUrl =
              (decoded['url'] ?? decoded['file_url'] ?? decoded['remoteUrl'])
                  ?.toString();
        } catch (_) {}

        _emitEvent('fileUploadCompleted', {
          'uploadId': uploadId,
          'fileName': fileName,
          'remoteUrl': remoteUrl ?? '',
          'response': responseBody,
        });

        return <String, dynamic>{
          'success': true,
          'uploadId': uploadId,
          'remoteUrl': remoteUrl,
          'response': responseBody,
        };
      } else {
        final err =
            'Upload failed with server status ${response.statusCode}: $responseBody';
        _emitEvent('fileUploadFailed', {
          'uploadId': uploadId,
          'fileName': fileName,
          'error': err,
        });
        return <String, dynamic>{'success': false, 'error': err};
      }
    } catch (e) {
      final err = 'Upload failed: $e';
      _emitEvent('fileUploadFailed', {
        'uploadId': uploadId,
        'fileName': localPath.split('/').last,
        'error': err,
      });
      return <String, dynamic>{'success': false, 'error': err};
    } finally {
      _activeUploads.remove(uploadId);
      client.close();
    }
  }

  /// Cancels an in-progress upload.
  void cancelUpload(String uploadId) {
    final client = _activeUploads.remove(uploadId);
    if (client != null) {
      try {
        client.close();
      } catch (_) {}
    }
    _emitEvent('fileUploadFailed', {
      'uploadId': uploadId,
      'error': 'Upload cancelled by user.',
    });
  }
}
