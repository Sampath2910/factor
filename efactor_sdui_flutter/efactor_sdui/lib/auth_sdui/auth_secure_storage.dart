import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// OS-backed persistence for the authenticated mobile session.
///
/// Access-token expiry is intentionally NOT interpreted on the client. The
/// backend is authoritative: a stored session remains usable until logout or a
/// protected API rejects it.
class AuthSecureStorage {
  static const _androidOptions = AndroidOptions(
    resetOnError: true,
  );
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  AuthSecureStorage({FlutterSecureStorage? storage})
    : _storage = storage ??
          const FlutterSecureStorage(
            aOptions: _androidOptions,
            iOptions: _iosOptions,
          );

  final FlutterSecureStorage _storage;

  static const _accessTokenKey = 'efactor.auth.access_token';
  static const _idTokenKey = 'efactor.auth.id_token';
  static const _refreshTokenKey = 'efactor.auth.refresh_token';
  static const _usernameKey = 'efactor.auth.username';
  static const _emailKey = 'efactor.auth.email';
  static const _userTypeKey = 'efactor.auth.user_type';
  static const _userIdKey = 'efactor.auth.user_id';

  Future<void> saveSession({
    required String accessToken,
    String? idToken,
    String? refreshToken,
    String? username,
    String? email,
    String? userType,
    String? userId,
  }) async {
    try {
      await Future.wait([
        _storage.write(key: _accessTokenKey, value: accessToken),
        if (idToken != null) _storage.write(key: _idTokenKey, value: idToken),
        if (refreshToken != null)
          _storage.write(key: _refreshTokenKey, value: refreshToken),
        if (username != null) _storage.write(key: _usernameKey, value: username),
        if (email != null) _storage.write(key: _emailKey, value: email),
        if (userType != null) _storage.write(key: _userTypeKey, value: userType),
        if (userId != null) _storage.write(key: _userIdKey, value: userId),
      ]);
    } catch (e) {
      debugPrint('[AUTH][SECURE_STORAGE] Error saving session: $e');
      // If saving fails due to corrupted key/keystore mismatch, reset and retry once
      try {
        await _storage.deleteAll();
        await _storage.write(key: _accessTokenKey, value: accessToken);
        if (idToken != null) await _storage.write(key: _idTokenKey, value: idToken);
        if (refreshToken != null) {
          await _storage.write(key: _refreshTokenKey, value: refreshToken);
        }
        if (username != null) await _storage.write(key: _usernameKey, value: username);
        if (email != null) await _storage.write(key: _emailKey, value: email);
        if (userType != null) await _storage.write(key: _userTypeKey, value: userType);
        if (userId != null) await _storage.write(key: _userIdKey, value: userId);
      } catch (retryError) {
        debugPrint('[AUTH][SECURE_STORAGE] Retry write session failed: $retryError');
      }
    }
  }

  Future<Map<String, String?>> readSession() async {
    try {
      final values = await Future.wait<String?>([
        _safeRead(_accessTokenKey),
        _safeRead(_idTokenKey),
        _safeRead(_refreshTokenKey),
        _safeRead(_usernameKey),
        _safeRead(_emailKey),
        _safeRead(_userTypeKey),
        _safeRead(_userIdKey),
      ]);

      return <String, String?>{
        'accessToken': values[0],
        'idToken': values[1],
        'refreshToken': values[2],
        'username': values[3],
        'email': values[4],
        'userType': values[5],
        'userId': values[6],
      };
    } catch (e) {
      debugPrint('[AUTH][SECURE_STORAGE] Error reading session: $e');
      // Self-heal: If keystore or ciphertext is corrupted (e.g. BadPaddingException),
      // wipe the invalid session so the device recovers immediately.
      await clearSession().catchError((_) {});
      return const <String, String?>{
        'accessToken': null,
        'idToken': null,
        'refreshToken': null,
        'username': null,
        'email': null,
        'userType': null,
        'userId': null,
      };
    }
  }

  Future<String?> _safeRead(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('[AUTH][SECURE_STORAGE] Safe read error for key "$key": $e');
      // If decryption fails for this key, clear it
      try {
        await _storage.delete(key: key);
      } catch (_) {}
      return null;
    }
  }

  Future<void> clearSession() async {
    try {
      await Future.wait([
        _safeDelete(_accessTokenKey),
        _safeDelete(_idTokenKey),
        _safeDelete(_refreshTokenKey),
        _safeDelete(_usernameKey),
        _safeDelete(_emailKey),
        _safeDelete(_userTypeKey),
        _safeDelete(_userIdKey),
      ]);
    } catch (e) {
      debugPrint('[AUTH][SECURE_STORAGE] Error clearing session: $e');
      try {
        await _storage.deleteAll();
      } catch (_) {}
    }
  }

  Future<void> _safeDelete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('[AUTH][SECURE_STORAGE] Safe delete error for key "$key": $e');
    }
  }
}

