import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thin helpers for essential device capabilities (camera, GPS, network, etc.).
///
/// Call these from UI / SDUI actions when a feature needs hardware access.
class DeviceCapabilities {
  DeviceCapabilities({
    ImagePicker? imagePicker,
    Connectivity? connectivity,
    DeviceInfoPlugin? deviceInfo,
  }) : _imagePicker = imagePicker ?? ImagePicker(),
       _connectivity = connectivity ?? Connectivity(),
       _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final ImagePicker _imagePicker;
  final Connectivity _connectivity;
  final DeviceInfoPlugin _deviceInfo;

  Future<bool> ensureCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<bool> ensurePhotosPermission() async {
    final status = await Permission.photos.request();
    return status.isGranted || status.isLimited;
  }

  Future<bool> ensureLocationPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Opens the camera and returns the captured image file, or null if cancelled.
  Future<XFile?> takePhoto() async {
    if (!await ensureCameraPermission()) return null;
    return _imagePicker.pickImage(source: ImageSource.camera, imageQuality: 85);
  }

  /// Opens the gallery and returns the selected image file, or null if cancelled.
  Future<XFile?> pickImageFromGallery() async {
    if (!await ensurePhotosPermission()) return null;
    return _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
  }

  /// Returns the current GPS position, or null if permission / service is unavailable.
  Future<Position?> getCurrentPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;
    if (!await ensureLocationPermission()) return null;

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  Future<bool> hasNetworkConnection() async {
    final results = await _connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;

  Future<Directory> getAppDocumentsDirectory() =>
      getApplicationDocumentsDirectory();

  Future<Map<String, String>> getDeviceInfo() async {
    if (Platform.isAndroid) {
      final info = await _deviceInfo.androidInfo;
      return <String, String>{
        'platform': 'android',
        'model': info.model,
        'brand': info.brand,
        'version': info.version.release,
      };
    }
    if (Platform.isIOS) {
      final info = await _deviceInfo.iosInfo;
      return <String, String>{
        'platform': 'ios',
        'model': info.utsname.machine,
        'name': info.name,
        'version': info.systemVersion,
      };
    }
    return <String, String>{'platform': Platform.operatingSystem};
  }
}
