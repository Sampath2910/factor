import 'package:cached_network_image/cached_network_image.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_renderer.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Grid SDUI Header & FeatureCard Visual Fidelity', () {
    testWidgets('Header renders profile avatar image and QR scanner icon', (tester) async {
      final schema = <String, dynamic>{
        'rootComponentId': 'grid-page-header',
        'designTokens': <String, dynamic>{
          'colors': <String, dynamic>{
            'textPrimary': '#2e1065',
            'textSecondary': '#6b7280',
            'accent': '#7c3aed',
            'surface': '#ffffff',
            'onAccent': '#ffffff',
          },
          'typography': <String, dynamic>{
            'pageTitle': <String, dynamic>{'size': 26.0},
            'pageSubtitle': <String, dynamic>{'size': 13.0},
          },
        },
        'components': <String, dynamic>{
          'grid-page-header': <String, dynamic>{
            'id': 'grid-page-header',
            'type': 'pageHeader',
            'title': 'Grid',
            'subtitle': 'Your professional network space',
            'appearance': <String, dynamic>{'logoHeight': 32.0},
            'actions': <dynamic>[
              <String, dynamic>{
                'id': 'grid-header-scanner',
                'iconToken': 'scanner',
                'actionId': 'grid-open-scanner',
                'appearance': <String, dynamic>{'size': 40.0, 'iconSize': 22.0},
              },
              <String, dynamic>{
                'id': 'grid-header-avatar',
                'type': 'avatarButton',
                'label': 'S',
                'color': '#7c3aed',
                'fontSize': 15.0,
                'imageUrl': 'https://efactor.tech/files/profile_images/_file6ae2ef7e10fb2-avatar.png',
                'actionId': 'navigate-profile',
              },
            ],
          },
        },
      };

      final state = GridSduiState(schema);
      final renderer = GridSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => renderer.buildRoot(context)),
          ),
        ),
      );

      // Verify QR scanner icon is rendered
      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);

      // Verify CachedNetworkImage is rendered for avatar
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      final cachedImage = tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(cachedImage.imageUrl, 'https://efactor.tech/files/profile_images/_file6ae2ef7e10fb2-avatar.png');
    });

    testWidgets('FeatureCard renders horizontal row layout with avatar, text, and badge', (tester) async {
      final schema = <String, dynamic>{
        'rootComponentId': 'grid-explore-professional-message',
        'designTokens': <String, dynamic>{
          'colors': <String, dynamic>{
            'textPrimary': '#1e1b4b',
            'textSecondary': '#6b7280',
            'accent': '#14b8a6',
            'surface': '#ffffff',
            'onAccent': '#ffffff',
          },
          'typography': <String, dynamic>{
            'pageSubtitle': <String, dynamic>{'size': 12.0},
          },
        },
        'components': <String, dynamic>{
          'grid-explore-professional-message': <String, dynamic>{
            'id': 'grid-explore-professional-message',
            'type': 'featureCard',
            'style': 'softCard',
            'title': 'Messages',
            'subtitle': 'No new messages',
            'icon': <String, dynamic>{
              'type': 'avatarButton',
              'label': 'M',
              'color': '#14b8a6',
              'backgroundColor': '#14b8a6',
              'fontSize': 14.0,
            },
            'color': '#14b8a6',
            'badge': 'Professional',
            'layout': <String, dynamic>{
              'direction': 'horizontal',
              'height': 72.0,
              'minHeight': 72.0,
            },
            'appearance': <String, dynamic>{
              'borderRadius': 16.0,
              'backgroundColor': '#eef2ff',
              'iconPosition': 'leading',
              'titlePosition': 'besideIcon',
              'showBadge': true,
              'iconSize': 42.0,
              'titleFontSize': 15.0,
              'subtitleFontSize': 12.0,
              'padding': 12.0,
            },
          },
        },
      };

      final state = GridSduiState(schema);
      final renderer = GridSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => renderer.buildRoot(context)),
          ),
        ),
      );

      // Verify title and subtitle are present and visible
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('No new messages'), findsOneWidget);

      // Verify badge is rendered
      expect(find.text('Professional'), findsOneWidget);

      // Verify avatar initial 'M' is rendered
      expect(find.text('M'), findsOneWidget);

      // Verify row layout is used
      expect(find.byType(Row), findsWidgets);
    });

    test('GridSduiState executes nativeScannerOpener on grid-open-scanner', () async {
      var scannerOpened = false;
      final schema = <String, dynamic>{
        'actions': <String, dynamic>{
          'grid-open-scanner': <String, dynamic>{
            'type': 'open-url',
            'url': 'https://efactor.tech/index.php/grid/qr',
            'title': 'Scan QR',
          },
        },
      };

      final state = GridSduiState(schema);
      state.nativeScannerOpener = () async {
        scannerOpened = true;
        return true;
      };

      await state.dispatch('grid-open-scanner');
      expect(scannerOpened, isTrue);
    });
  });
}
