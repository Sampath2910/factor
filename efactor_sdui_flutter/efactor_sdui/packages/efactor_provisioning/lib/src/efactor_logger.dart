import 'package:flutter/foundation.dart';

/// Log levels, ordered by severity.
enum EfLogLevel { debug, info, warn, error, none }

/// Central logger for the whole plugin.
///
/// Mirrors the Android library's `ENABLE_*_LOGS` BuildConfig flags, but in one
/// place and controllable from Dart at runtime. Every layer (Dart API, method
/// channel, and — via a bridged sink — the native side) funnels through here so
/// you can watch the entire provisioning flow in one stream while testing.
///
/// Usage:
///   EfLog.level = EfLogLevel.debug;            // verbosity
///   EfLog.onRecord = (r) => print(r);          // or pipe to a UI console
class EfLog {
  EfLog._();

  /// Minimum level that will be emitted. Set to [EfLogLevel.none] to silence.
  static EfLogLevel level = kReleaseMode ? EfLogLevel.info : EfLogLevel.debug;

  /// Optional sink. When set, every record is delivered here (e.g. an on-screen
  /// debug console in the example app). Always also printed in debug builds.
  static void Function(EfLogRecord record)? onRecord;

  static void d(String tag, String msg) => _log(EfLogLevel.debug, tag, msg);
  static void i(String tag, String msg) => _log(EfLogLevel.info, tag, msg);
  static void w(String tag, String msg) => _log(EfLogLevel.warn, tag, msg);
  static void e(String tag, String msg, [Object? error, StackTrace? st]) =>
      _log(EfLogLevel.error, tag, msg, error, st);

  static void _log(
    EfLogLevel lvl,
    String tag,
    String msg, [
    Object? error,
    StackTrace? st,
  ]) {
    if (lvl.index < level.index || level == EfLogLevel.none) return;
    final record = EfLogRecord(
      level: lvl,
      tag: tag,
      message: msg,
      error: error,
      stackTrace: st,
      time: DateTime.now(),
    );
    onRecord?.call(record);
    if (kDebugMode) {
      // ignore: avoid_print
      print(record.toString());
    }
  }
}

/// A single log line with structured fields, so a UI console can render/filter.
class EfLogRecord {
  EfLogRecord({
    required this.level,
    required this.tag,
    required this.message,
    required this.time,
    this.error,
    this.stackTrace,
  });

  final EfLogLevel level;
  final String tag;
  final String message;
  final DateTime time;
  final Object? error;
  final StackTrace? stackTrace;

  String get _lvlChar => switch (level) {
        EfLogLevel.debug => 'D',
        EfLogLevel.info => 'I',
        EfLogLevel.warn => 'W',
        EfLogLevel.error => 'E',
        EfLogLevel.none => '-',
      };

  @override
  String toString() {
    final t = time.toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    final base = '$t $_lvlChar/eFactor:$tag  $message';
    if (error != null) return '$base\n    ↳ $error';
    return base;
  }
}
