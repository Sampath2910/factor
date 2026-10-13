import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

/// Full-screen QR scanner used by the native `openScanner` action.
///
/// Accepts QR codes only. If a barcode / other format is detected, a message
/// asks the user to show a QR code instead.
class ScannerPage extends StatefulWidget {
  const ScannerPage({
    super.key,
    this.formats = const ['qr'],
    this.camera = 'back',
    this.qrOnly = true,
  });

  final List<String> formats;
  final String camera;

  /// When true, only QR codes complete the scan; barcodes show a warning.
  final bool qrOnly;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  late final MobileScannerController _controller;
  bool _handled = false;
  bool _permissionDenied = false;
  String? _error;
  String? _hintMessage;
  Color _hintColor = const Color(0xFFE31E24);

  @override
  void initState() {
    super.initState();
    // Detect QR + common barcodes so we can warn on non-QR codes.
    _controller = MobileScannerController(
      facing: widget.camera.toLowerCase() == 'front'
          ? CameraFacing.front
          : CameraFacing.back,
      formats: widget.qrOnly
          ? const [
              BarcodeFormat.qrCode,
              BarcodeFormat.code128,
              BarcodeFormat.code39,
              BarcodeFormat.code93,
              BarcodeFormat.ean13,
              BarcodeFormat.ean8,
              BarcodeFormat.upcA,
              BarcodeFormat.upcE,
              BarcodeFormat.dataMatrix,
              BarcodeFormat.pdf417,
              BarcodeFormat.aztec,
            ]
          : _mapFormats(widget.formats),
      detectionSpeed: DetectionSpeed.normal,
    );
    _ensurePermission();
  }

  Future<void> _ensurePermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() => _permissionDenied = true);
    }
  }

  List<BarcodeFormat> _mapFormats(List<String> formats) {
    final resolved = <BarcodeFormat>{};
    for (final raw in formats) {
      switch (raw.toLowerCase().trim()) {
        case 'qr':
        case 'qrcode':
        case 'qr_code':
          resolved.add(BarcodeFormat.qrCode);
        case 'code128':
          resolved.add(BarcodeFormat.code128);
        case 'code39':
          resolved.add(BarcodeFormat.code39);
        case 'ean13':
          resolved.add(BarcodeFormat.ean13);
        case 'ean8':
          resolved.add(BarcodeFormat.ean8);
        case 'upc_a':
        case 'upca':
          resolved.add(BarcodeFormat.upcA);
        case 'upc_e':
        case 'upce':
          resolved.add(BarcodeFormat.upcE);
        case 'barcode':
        case 'all':
          resolved.addAll(const [
            BarcodeFormat.qrCode,
            BarcodeFormat.code128,
            BarcodeFormat.code39,
            BarcodeFormat.code93,
            BarcodeFormat.ean13,
            BarcodeFormat.ean8,
            BarcodeFormat.upcA,
            BarcodeFormat.upcE,
            BarcodeFormat.dataMatrix,
            BarcodeFormat.pdf417,
            BarcodeFormat.aztec,
          ]);
        default:
          break;
      }
    }
    if (resolved.isEmpty) {
      return const [BarcodeFormat.qrCode];
    }
    return resolved.toList();
  }

  void _showHint(String message, {Color color = const Color(0xFFE31E24)}) {
    if (!mounted) return;
    setState(() {
      _hintMessage = message;
      _hintColor = color;
    });
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final barcode = barcodes.first;
    final value = barcode.rawValue?.trim();
    if (value == null || value.isEmpty) {
      _showHint('No data found. Please show a clear QR code.');
      return;
    }

    final formatName = _formatName(barcode.format);
    final isQr = barcode.format == BarcodeFormat.qrCode;

    if (widget.qrOnly && !isQr) {
      _showHint(
        'That is a barcode ($formatName), not a QR code.\n'
        'Please show a QR code only.',
      );
      return;
    }

    final allowed = _allowedFormatNames(widget.formats);
    if (!widget.qrOnly &&
        allowed.isNotEmpty &&
        !allowed.contains(formatName) &&
        !(allowed.contains('barcode') && !isQr) &&
        !(allowed.contains('qr') && isQr)) {
      _showHint(
        isQr
            ? 'QR code is not accepted here. Please show the required code.'
            : 'Unsupported code ($formatName).\nPlease show a QR code.',
      );
      return;
    }

    _handled = true;
    _showHint('QR code scanned successfully!', color: const Color(0xFF10B981));

    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      Navigator.of(context).pop(<String, dynamic>{
        'value': value,
        'format': formatName,
        'displayValue': barcode.displayValue ?? value,
        'success': true,
      });
    });
  }

  Set<String> _allowedFormatNames(List<String> formats) {
    final out = <String>{};
    for (final raw in formats) {
      final key = raw.toLowerCase().trim();
      if (key == 'qr' || key == 'qrcode' || key == 'qr_code') {
        out.add('qr');
      } else if (key == 'barcode' || key == 'all') {
        out.add('barcode');
      } else {
        out.add(key);
      }
    }
    return out;
  }

  String _formatName(BarcodeFormat format) {
    switch (format) {
      case BarcodeFormat.qrCode:
        return 'qr';
      case BarcodeFormat.code128:
        return 'code128';
      case BarcodeFormat.code39:
        return 'code39';
      case BarcodeFormat.code93:
        return 'code93';
      case BarcodeFormat.ean13:
        return 'ean13';
      case BarcodeFormat.ean8:
        return 'ean8';
      case BarcodeFormat.upcA:
        return 'upc_a';
      case BarcodeFormat.upcE:
        return 'upc_e';
      case BarcodeFormat.dataMatrix:
        return 'data_matrix';
      case BarcodeFormat.pdf417:
        return 'pdf417';
      case BarcodeFormat.aztec:
        return 'aztec';
      default:
        return format.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan QR'),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flash_on),
          ),
          IconButton(
            tooltip: 'Flip camera',
            onPressed: () => _controller.switchCamera(),
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: _permissionDenied
          ? _PermissionDenied(
              onOpenSettings: openAppSettings,
              onCancel: () => Navigator.of(context).pop(),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) {
                    _error ??= error.errorDetails?.message ?? error.toString();
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    );
                  },
                ),
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 260,
                      height: 260,
                      decoration: BoxDecoration(
                        border: Border.all(color: _hintColor, width: 2.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Text(
                            'Show a QR code inside the frame',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_hintMessage != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                        child: Material(
                          color: _hintColor,
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _hintColor == const Color(0xFF10B981)
                                      ? Icons.check_circle
                                      : Icons.qr_code_2,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _hintMessage!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 0, 24, 48),
                      child: Text(
                        'Only QR codes are accepted.\nBarcodes will not work.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _PermissionDenied extends StatelessWidget {
  const _PermissionDenied({
    required this.onOpenSettings,
    required this.onCancel,
  });

  final Future<bool> Function() onOpenSettings;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.camera_alt_outlined,
              color: Colors.white54,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera permission is required to scan a QR code.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onOpenSettings,
              child: const Text('Open settings'),
            ),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}
