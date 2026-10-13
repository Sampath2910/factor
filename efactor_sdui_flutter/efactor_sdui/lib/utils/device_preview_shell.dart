import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Predefined global smartphone device archetypes for interactive testing.
class DevicePreset {
  const DevicePreset({
    required this.name,
    required this.shortName,
    required this.size,
    required this.devicePixelRatio,
    this.defaultBottomInset = 0.0,
    this.hasPhysicalButtons = false,
  });

  final String name;
  final String shortName;
  final Size size;
  final double devicePixelRatio;
  final double defaultBottomInset;
  final bool hasPhysicalButtons;
}

const List<DevicePreset> kGlobalDevicePresets = [
  DevicePreset(
    name: 'Samsung Galaxy S25',
    shortName: 'S25 (360p)',
    size: Size(360, 780),
    devicePixelRatio: 3.0,
    defaultBottomInset: 48.0,
    hasPhysicalButtons: true,
  ),
  DevicePreset(
    name: 'Realme Narzo 30',
    shortName: 'Narzo 30 (392p)',
    size: Size(392, 850),
    devicePixelRatio: 2.75,
    defaultBottomInset: 48.0,
    hasPhysicalButtons: true,
  ),
  DevicePreset(
    name: 'iPhone SE (1st Gen / Budget)',
    shortName: 'SE (320p)',
    size: Size(320, 568),
    devicePixelRatio: 2.0,
    defaultBottomInset: 0.0,
  ),
  DevicePreset(
    name: 'iPhone 16 Pro Max',
    shortName: '16 Pro Max (430p)',
    size: Size(430, 932),
    devicePixelRatio: 3.0,
    defaultBottomInset: 34.0,
  ),
  DevicePreset(
    name: 'Compact Tablet / Z Fold Inner',
    shortName: 'Tablet (600p)',
    size: Size(600, 960),
    devicePixelRatio: 2.0,
    defaultBottomInset: 48.0,
  ),
];

/// Interactive In-App Multi-Device Preview Shell.
///
/// In debug mode, displays an interactive floating device inspector allowing
/// one-tap switching between Samsung Galaxy S25, Realme Narzo 30, iPhone SE,
/// and iPhone 16 Pro Max, with live 3-Button Nav and Font Zoom toggles.
/// In release mode, renders [child] directly with zero overhead.
class DevicePreviewShell extends StatefulWidget {
  const DevicePreviewShell({super.key, required this.child});

  final Widget child;

  @override
  State<DevicePreviewShell> createState() => _DevicePreviewShellState();
}

class _DevicePreviewShellState extends State<DevicePreviewShell> {
  DevicePreset? _activePreset;
  bool _showNavBar = true;
  double _fontScale = 1.0;
  bool _isMenuOpen = false;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // Simulated or Native Viewport Surface
          Positioned.fill(
            child: _activePreset == null
                ? widget.child
                : _buildSimulatedDeviceFrame(context, _activePreset!),
          ),

          // Floating Quick-Switch Pill
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 12,
            child: Material(
              type: MaterialType.transparency,
              child: GestureDetector(
                onTap: () => setState(() => _isMenuOpen = !_isMenuOpen),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _activePreset == null
                        ? Colors.black.withValues(alpha: 0.75)
                        : Colors.indigo.shade900.withValues(alpha: 0.90),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _activePreset == null
                          ? Colors.white24
                          : Colors.amberAccent,
                      width: 1.2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _activePreset == null
                            ? Icons.phone_android
                            : Icons.devices_other,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _activePreset == null
                            ? 'Native Device'
                            : '${_activePreset!.shortName} (${_fontScale}x)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _isMenuOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                        size: 16,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Expandable Control Panel Drawer
          if (_isMenuOpen)
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.of(context).padding.top + 48,
              child: Material(
                elevation: 16,
                borderRadius: BorderRadius.circular(16),
                color: const Color(0xFF1E2430),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '📱 Universal Device Switcher',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => setState(() => _isMenuOpen = false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Device Presets Row
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _buildPresetChip(null, 'Native'),
                          ...kGlobalDevicePresets.map(
                            (p) => _buildPresetChip(p, p.shortName),
                          ),
                        ],
                      ),

                      const Divider(color: Colors.white24, height: 20),

                      // Controls: 3-Button Nav Bar & Font Scaling
                      Row(
                        children: [
                          // 3-Button Nav Toggle
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() => _showNavBar = !_showNavBar),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: _showNavBar
                                      ? Colors.blue.withValues(alpha: 0.25)
                                      : Colors.white10,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _showNavBar
                                        ? Colors.blueAccent
                                        : Colors.white24,
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.navigation,
                                      size: 14,
                                      color: _showNavBar
                                          ? Colors.blueAccent
                                          : Colors.white60,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _showNavBar ? '3-Button: ON' : '3-Button: OFF',
                                      style: TextStyle(
                                        color: _showNavBar
                                            ? Colors.white
                                            : Colors.white60,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // Font Scale Selector
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<double>(
                                  value: _fontScale,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF252D3D),
                                  icon: const Icon(
                                    Icons.text_fields,
                                    size: 14,
                                    color: Colors.white70,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 1.0,
                                      child: Text(
                                        'Font 1.0x',
                                        style: TextStyle(color: Colors.white, fontSize: 11),
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 1.15,
                                      child: Text(
                                        'Font 1.15x',
                                        style: TextStyle(color: Colors.white, fontSize: 11),
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 1.30,
                                      child: Text(
                                        'Font 1.30x',
                                        style: TextStyle(color: Colors.white, fontSize: 11),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) setState(() => _fontScale = val);
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPresetChip(DevicePreset? preset, String label) {
    final isSelected = _activePreset == preset;
    return InkWell(
      onTap: () {
        setState(() {
          _activePreset = preset;
          _isMenuOpen = false;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? Colors.indigoAccent : Colors.white12,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Colors.white : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildSimulatedDeviceFrame(BuildContext context, DevicePreset preset) {
    final bottomInset = _showNavBar ? preset.defaultBottomInset : 0.0;

    return Container(
      color: const Color(0xFF10141C),
      child: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: Container(
            width: preset.size.width,
            height: preset.size.height,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white30, width: 2.5),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black87,
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // Inner Simulated Application Viewport
                Positioned.fill(
                  child: MediaQuery(
                    data: MediaQueryData(
                      size: preset.size,
                      devicePixelRatio: preset.devicePixelRatio,
                      padding: EdgeInsets.only(
                        top: 28,
                        bottom: bottomInset,
                      ),
                      viewPadding: EdgeInsets.only(
                        top: 28,
                        bottom: bottomInset,
                      ),
                      textScaler: TextScaler.linear(_fontScale),
                    ),
                    child: widget.child,
                  ),
                ),

                // Simulated Android 3-Button Navigation Bar (if enabled)
                if (_showNavBar && bottomInset > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: bottomInset,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.90),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          const Icon(Icons.arrow_back, size: 16, color: Colors.white70),
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white70, width: 2),
                            ),
                          ),
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white70, width: 2),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
