import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_renderer.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';
import 'package:efactor_sdui/sdui/schema_guard.dart';
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
      expect(state.lastError, isNull);
    });

    test('GridSduiState dispatches open-url targeting /grid/qr to inAppWebViewOpener', () async {
      Uri? openedUri;
      final schema = <String, dynamic>{
        'actions': <String, dynamic>{
          'grid-open-qr-link': <String, dynamic>{
            'type': 'open-url',
            'url': 'https://efactor.tech/index.php/grid/qr?grid_sso=test123',
            'title': 'QR Link',
            'openIn': 'inAppWebView',
          },
        },
      };

      final state = GridSduiState(schema);
      state.inAppWebViewOpener = (Uri uri, {String? title}) async {
        openedUri = uri;
        return true;
      };

      await state.dispatch('grid-open-qr-link');
      expect(openedUri, isNotNull);
      expect(openedUri!.path, '/index.php/grid/qr');
      expect(state.lastError, isNull);
    });

    test('GridSduiState dispatches open-url targeting /grid/profile to inAppWebViewOpener', () async {
      Uri? openedUri;
      final schema = <String, dynamic>{
        'actions': <String, dynamic>{
          'grid-open-profile': <String, dynamic>{
            'type': 'open-url',
            'url': 'https://efactor.tech/index.php/grid/profile?grid_sso=profile123',
            'title': 'Profile',
            'openIn': 'inAppWebView',
          },
        },
      };

      final state = GridSduiState(schema);
      state.inAppWebViewOpener = (Uri uri, {String? title}) async {
        openedUri = uri;
        return true;
      };

      await state.dispatch('grid-open-profile');
      expect(openedUri, isNotNull);
      expect(openedUri!.path, '/index.php/grid/profile');
      expect(state.lastError, isNull);
    });
  });

  group('GRID Schema-Driven Theme, Responsive Header, Typography & Dark Mode', () {
    Map<String, dynamic> buildThemeSchema({
      String defaultMode = 'system',
      String rootComponentId = 'grid-page',
      List<String> pageChildren = const <String>[
        'grid-page-header',
        'grid-feature-professional-space',
        'grid-share-qr',
        'grid-explore-section',
        'grid-quote',
      ],
    }) {
      return <String, dynamic>{
        'schema_rev': 'grid-logo-globe-3',
        'rootComponentId': rootComponentId,
        'theme': <String, dynamic>{
          'defaultMode': defaultMode,
          'systemFollows': 'device',
          'modes': <String, dynamic>{
            'light': <String, dynamic>{
              'pageBackground': '#eef4fb',
              'surface': '#ffffff',
              'onSurface': '#0b1b33',
              'textPrimary': '#0b1b33',
              'textSecondary': '#64748b',
              'textMuted': '#94a3b8',
              'border': '#cbd5e1',
              'accent': '#7c3aed',
              'onAccent': '#ffffff',
            },
            'dark': <String, dynamic>{
              'pageBackground': '#050b16',
              'surface': '#1a1f2e',
              'onSurface': '#f8fafc',
              'textPrimary': '#f8fafc',
              'textSecondary': '#94a3b8',
              'textMuted': '#64748b',
              'border': '#2a3344',
              'accent': '#8b5cf6',
              'onAccent': '#ffffff',
            },
          },
        },
        'designTokens': <String, dynamic>{
          'colors': <String, dynamic>{
            'pageBackground': '#eef4fb',
            'surface': '#ffffff',
            'onSurface': '#0b1b33',
            'textPrimary': '#0b1b33',
            'textSecondary': '#64748b',
            'textMuted': '#94a3b8',
            'border': '#cbd5e1',
            'accent': '#7c3aed',
            'onAccent': '#ffffff',
          },
          'typography': <String, dynamic>{
            'fontFamily': 'Plus Jakarta Sans',
            'pageTitle': <String, dynamic>{
              'fontFamily': 'Plus Jakarta Sans',
              'size': 18.0,
              'weight': 800,
              'maxLines': 2,
            },
            'pageSubtitle': <String, dynamic>{
              'fontFamily': 'Plus Jakarta Sans',
              'size': 11.0,
              'weight': 500,
              'maxLines': 2,
            },
            'tagline': <String, dynamic>{
              'fontFamily': 'Plus Jakarta Sans',
              'size': 11.0,
              'weight': 500,
              'maxLines': 2,
            },
          },
        },
        'typography': <String, dynamic>{
          'fontFamily': 'Plus Jakarta Sans',
          'title': <String, dynamic>{
            'fontFamily': 'Plus Jakarta Sans',
            'size': 18.0,
            'weight': 800,
            'maxLines': 2,
          },
          'pageTitle': <String, dynamic>{
            'fontFamily': 'Plus Jakarta Sans',
            'size': 18.0,
            'weight': 800,
            'maxLines': 2,
          },
          'pageSubtitle': <String, dynamic>{
            'fontFamily': 'Plus Jakarta Sans',
            'size': 11.0,
            'weight': 500,
            'maxLines': 2,
          },
          'tagline': <String, dynamic>{
            'fontFamily': 'Plus Jakarta Sans',
            'size': 11.0,
            'weight': 500,
            'maxLines': 2,
          },
        },
        'actions': <String, dynamic>{
          'grid-open-scanner': <String, dynamic>{
            'type': 'open-scanner',
            'label': 'Scan QR',
          },
          'grid-open-profile': <String, dynamic>{
            'type': 'open-url',
            'url': 'https://efactor.tech/index.php/grid/profile',
            'openIn': 'inAppWebView',
          },
          'refresh-grid': <String, dynamic>{
            'type': 'sequence',
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'set-state',
                'path': 'refreshing',
                'value': true,
              },
              <String, dynamic>{
                'type': 'refresh-data-source',
                'dataSourceId': 'grid',
              },
            ],
          },
        },
        'components': <String, dynamic>{
          'grid-page': <String, dynamic>{
            'id': 'grid-page',
            'type': 'scrollPage',
            'children': pageChildren,
            'layout': <String, dynamic>{
              'padding': <String, dynamic>{
                'top': 12.0,
                'bottom': 24.0,
                'left': 16.0,
                'right': 16.0,
              },
              'gap': 12.0,
            },
            'appearance': <String, dynamic>{
              'backgroundColor': '#eef4fb',
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#050b16',
            },
          },
          'grid-page-header': <String, dynamic>{
            'id': 'grid-page-header',
            'type': 'pageHeader',
            'logoUrl': 'https://efactor.tech/assets/images/GRID_Logo.png',
            'logoUrlDark': 'https://efactor.tech/assets/images/dark_grid.png',
            'eyebrow': 'WELCOME TO GRID',
            'title': 'Welcome back',
            'subtitle': 'Your professional space',
            'tagline': 'Connect. Collaborate. Grow.',
            'orbitGlobeImageUrl':
                'https://efactor.tech/assets/images/grid-orbit-globe.png',
            'orbitGlobeImageUrlDark':
                'https://efactor.tech/assets/images/grid-orbit-globe.png',
            'orbitGlobePlacement': 'heroRight',
            'orbitGlobeClip': false,
            'layout': <String, dynamic>{
              'heroGlobeWidth': 160.0,
              'heroGlobeHeight': 160.0,
              'responsive': <String, dynamic>{
                'narrow': <String, dynamic>{
                  'logoHeight': 44.0,
                  'heroGlobeWidth': 148.0,
                  'heroGlobeHeight': 148.0,
                  'titleFontSize': 18.0,
                  'subtitleFontSize': 11.0,
                },
                'compact': <String, dynamic>{
                  'logoHeight': 48.0,
                  'heroGlobeWidth': 160.0,
                  'heroGlobeHeight': 160.0,
                  'titleFontSize': 18.0,
                  'subtitleFontSize': 11.0,
                },
                'regular': <String, dynamic>{
                  'logoHeight': 48.0,
                  'heroGlobeWidth': 160.0,
                  'heroGlobeHeight': 160.0,
                },
                'medium': <String, dynamic>{
                  'logoHeight': 52.0,
                  'heroGlobeWidth': 168.0,
                  'heroGlobeHeight': 168.0,
                },
                'expanded': <String, dynamic>{
                  'logoHeight': 56.0,
                  'heroGlobeWidth': 168.0,
                  'heroGlobeHeight': 168.0,
                },
              },
            },
            'appearance': <String, dynamic>{
              'logoHeight': 48.0,
              'logoMaxWidth': 168.0,
              'orbitGlobeSize': 160.0,
              'eyebrowColor': '#7c3aed',
              'titleColor': '#0b1b33',
              'subtitleColor': '#64748b',
              'taglineColor': '#64748b',
            },
            'appearanceDark': <String, dynamic>{
              'logoUrlDark': 'https://efactor.tech/assets/images/dark_grid.png',
              'logoHeight': 48.0,
              'logoMaxWidth': 168.0,
              'eyebrowColor': '#a78bfa',
              'titleColor': '#f8fafc',
              'subtitleColor': '#94a3b8',
              'taglineColor': '#94a3b8',
            },
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'grid-header-scanner',
                'iconToken': 'scanner',
                'actionId': 'grid-open-scanner',
                'appearance': <String, dynamic>{
                  'size': 48.0,
                  'iconSize': 22.0,
                  'backgroundColor': '#ffffff',
                  'foregroundColor': '#0b1b33',
                  'borderColor': '#e5e7eb',
                },
                'appearanceDark': <String, dynamic>{
                  'size': 48.0,
                  'iconSize': 22.0,
                  'backgroundColor': '#1a1f2e',
                  'foregroundColor': '#f8fafc',
                  'borderColor': '#2a3344',
                },
              },
              <String, dynamic>{
                'id': 'grid-header-avatar',
                'type': 'avatarButton',
                'label': 'R',
                'fontSize': 15.0,
                'actionId': 'grid-open-profile',
                'appearance': <String, dynamic>{
                  'size': 48.0,
                  'backgroundColor': '#7c3aed',
                  'foregroundColor': '#ffffff',
                },
                'appearanceDark': <String, dynamic>{
                  'size': 48.0,
                  'backgroundColor': '#8b5cf6',
                  'foregroundColor': '#ffffff',
                },
              },
            ],
          },
          'grid-feature-professional-space': <String, dynamic>{
            'id': 'grid-feature-professional-space',
            'type': 'featureCard',
            'title': 'Professional Space',
            'subtitle': 'Manage your workspace',
            'badge': 'Live',
            'icon': 'work',
            'layout': <String, dynamic>{
              'minHeight': 72.0,
            },
            'appearance': <String, dynamic>{
              'backgroundColor': '#ffffff',
              'borderColor': '#e2e8f0',
              'titleColor': '#0b1b33',
              'subtitleColor': '#64748b',
              'borderRadius': 18.0,
              'iconSize': 32.0,
              'titleFontSize': 16.0,
              'subtitleFontSize': 12.0,
              'padding': 16.0,
            },
            'appearanceDark': <String, dynamic>{
              'backgroundGradient': <String, dynamic>{
                'start': '#1e1b4b',
                'end': '#1a1f2e',
              },
              'borderColor': '#3b4254',
              'titleColor': '#f8fafc',
              'subtitleColor': '#94a3b8',
            },
          },
          'grid-share-qr': <String, dynamic>{
            'id': 'grid-share-qr',
            'type': 'shareQrCard',
            'title': 'Share Profile QR',
            'subtitle': 'Scan to connect',
            'data': 'https://efactor.tech/grid/profile/655',
            'selectedMode': 'professional',
            'modes': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'professional',
                'label': 'Professional',
                'selected': true,
              },
              <String, dynamic>{
                'id': 'circle',
                'label': 'Circle',
              },
            ],
            'layout': <String, dynamic>{'gap': 10.0},
            'appearance': <String, dynamic>{
              'backgroundColor': '#ffffff',
              'borderColor': '#e2e8f0',
              'titleColor': '#0b1b33',
              'subtitleColor': '#64748b',
              'qrBackgroundColor': '#ffffff',
              'titleFontSize': 16.0,
              'subtitleFontSize': 12.0,
              'borderRadius': 18.0,
              'padding': 16.0,
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#1a1f2e',
              'borderColor': '#2a3344',
              'titleColor': '#f8fafc',
              'subtitleColor': '#94a3b8',
              'qrBackgroundColor': '#ffffff',
            },
          },
          'grid-explore-section': <String, dynamic>{
            'id': 'grid-explore-section',
            'type': 'section',
            'title': 'Explore',
            'children': <String>['grid-explore-row'],
            'appearance': <String, dynamic>{
              'titleColor': '#0b1b33',
              'titleFontSize': 14.0,
              'gap': 10.0,
            },
            'appearanceDark': <String, dynamic>{
              'titleColor': '#f8fafc',
            },
          },
          'grid-explore-row': <String, dynamic>{
            'id': 'grid-explore-row',
            'type': 'responsiveGrid',
            'children': <String>['grid-explore-professional-message'],
            'layout': <String, dynamic>{
              'columns': 1,
              'columnGap': 8.0,
              'rowGap': 8.0,
            },
          },
          'grid-explore-professional-message': <String, dynamic>{
            'id': 'grid-explore-professional-message',
            'type': 'featureCard',
            'title': 'Updates',
            'subtitle': '2 new updates',
            'icon': 'notifications',
            'layout': <String, dynamic>{'minHeight': 72.0},
            'appearance': <String, dynamic>{
              'backgroundColor': '#ffffff',
              'borderColor': '#e2e8f0',
              'titleColor': '#0b1b33',
              'subtitleColor': '#64748b',
              'borderRadius': 16.0,
              'iconSize': 42.0,
              'titleFontSize': 15.0,
              'subtitleFontSize': 12.0,
              'padding': 14.0,
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#1a1f2e',
              'borderColor': '#2a3344',
              'titleColor': '#f8fafc',
              'subtitleColor': '#94a3b8',
            },
          },
          'grid-quote': <String, dynamic>{
            'id': 'grid-quote',
            'type': 'quoteBlock',
            'title': 'Build meaningful connections',
            'attribution': 'GRID',
            'appearance': <String, dynamic>{
              'backgroundColor': '#ffffff',
              'borderColor': '#e2e8f0',
              'textColor': '#0b1b33',
              'borderRadius': 14.0,
              'padding': 14.0,
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#1a1f2e',
              'borderColor': '#2a3344',
              'textColor': '#f8fafc',
            },
          },
          'grid-loading': <String, dynamic>{
            'id': 'grid-loading',
            'type': 'skeleton',
            'appearance': <String, dynamic>{
              'backgroundColor': '#eef4fb',
              'cardColor': '#ffffff',
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#050b16',
              'cardColor': '#1a1f2e',
            },
          },
          'grid-error': <String, dynamic>{
            'id': 'grid-error',
            'type': 'errorState',
            'title': 'Unable to load GRID',
            'subtitle': 'Check your connection',
            'retryActionId': 'refresh-grid',
            'retryLabel': 'Retry',
            'appearance': <String, dynamic>{
              'backgroundColor': '#eef4fb',
              'titleColor': '#0b1b33',
              'subtitleColor': '#64748b',
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#050b16',
              'titleColor': '#f8fafc',
              'subtitleColor': '#94a3b8',
            },
          },
        },
        'content': <String, dynamic>{
          'stats': <Map<String, dynamic>>[
            <String, dynamic>{'label': 'Connections', 'value': '12'},
            <String, dynamic>{'label': 'Updates', 'value': '2'},
          ],
        },
        'layoutPolicy': <String, dynamic>{
          'responsiveBreakpoints': <String, dynamic>{
            'narrow': 0,
            'compact': 320,
            'regular': 480,
            'medium': 600,
            'expanded': 840,
          },
        },
      };
    }

    test('GridSduiState resolves light, dark, and system modes and dark appearances',
        () {
      final fixedLight = GridSduiState(
        buildThemeSchema(defaultMode: 'light'),
        platformBrightness: Brightness.dark,
      );
      expect(fixedLight.configuredThemeMode, 'light');
      expect(fixedLight.resolvedThemeMode, 'light');
      expect(fixedLight.isDarkMode, isFalse);
      expect(fixedLight.tokenColor('colors.pageBackground'),
          const Color(0xFFEEF4FB));

      final fixedDark = GridSduiState(
        buildThemeSchema(defaultMode: 'dark'),
        platformBrightness: Brightness.light,
      );
      expect(fixedDark.configuredThemeMode, 'dark');
      expect(fixedDark.resolvedThemeMode, 'dark');
      expect(fixedDark.isDarkMode, isTrue);
      expect(fixedDark.tokenColor('colors.pageBackground'),
          const Color(0xFF050B16));

      final system = GridSduiState(
        buildThemeSchema(defaultMode: 'system'),
        platformBrightness: Brightness.light,
      );
      expect(system.isDarkMode, isFalse);
      expect(
        system.resolvedAppearance(system.component('grid-page-header')!)['titleColor'],
        '#0b1b33',
      );

      // Switch to dark without recreating state
      var notifyCount = 0;
      system.addListener(() => notifyCount++);
      system.updatePlatformBrightness(Brightness.dark);
      expect(notifyCount, 1);
      expect(system.isDarkMode, isTrue);
      expect(system.tokenColor('colors.pageBackground'), const Color(0xFF050B16));
      expect(system.tokenColor('colors.surface'), const Color(0xFF1A1F2E));
      final resolvedHeader =
          system.resolvedAppearance(system.component('grid-page-header')!);
      expect(
        resolvedHeader['logoUrlDark'],
        'https://efactor.tech/assets/images/dark_grid.png',
      );
      expect(resolvedHeader['titleColor'], '#f8fafc');
      expect(resolvedHeader['logoHeight'], 48.0);

      // Verify synthesized stats row did not hardcode #ffffff background
      final statsRow = system.component('grid-stats-row')!;
      expect((statsRow['appearance'] as Map)['backgroundColor'], isNull);

      // Verify solid dark appearance overrides light gradient rather than leaking it
      final lightGradWithSolidDark = GridSduiState(<String, dynamic>{
        'theme': <String, dynamic>{'defaultMode': 'dark'},
        'components': <String, dynamic>{
          'c': <String, dynamic>{
            'appearance': <String, dynamic>{
              'backgroundGradient': <String, dynamic>{
                'start': '#ffffff',
                'end': '#eef4fb',
              },
            },
            'appearanceDark': <String, dynamic>{
              'backgroundColor': '#1a1f2e',
            },
          },
        },
      });
      final resolvedCard =
          lightGradWithSolidDark.resolvedAppearance(lightGradWithSolidDark.component('c')!);
      expect(resolvedCard['backgroundColor'], '#1a1f2e');
      expect(resolvedCard.containsKey('backgroundGradient'), isFalse);
    });

    testWidgets(
        'Grid renderer applies dark logo, dark tokens, Plus Jakarta Sans typography, 48x48 actions, and responsive globe widths',
        (tester) async {
      final state = GridSduiState(
        buildThemeSchema(defaultMode: 'system'),
        platformBrightness: Brightness.light,
      );
      final renderer = GridSduiRenderer(state);

      // Compact 400dp -> 48px logo, 160px globe
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) => renderer.buildRoot(context),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SchemaIssueWidget), findsNothing);

      // Light mode logo & globe
      var images = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .toList();
      final lightLogo = images.firstWhere(
        (i) => i.imageUrl == 'https://efactor.tech/assets/images/GRID_Logo.png',
      );
      expect(lightLogo.height, 48.0);
      expect(lightLogo.fit, BoxFit.contain);

      // Verify ConstrainedBox(maxWidth: 168.0) wraps the logo
      final logoMaxBoxes = tester
          .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
          .where((b) => b.constraints.maxWidth == 168.0);
      expect(logoMaxBoxes, isNotEmpty);

      // Verify compact 160x160 PNG globe
      final globeCompact = images.firstWhere(
        (i) =>
            i.imageUrl ==
            'https://efactor.tech/assets/images/grid-orbit-globe.png',
      );
      expect(globeCompact.width, 160.0);
      expect(globeCompact.height, 160.0);

      // Verify Plus Jakarta Sans + 18/w800/maxLines 2 title + 11/w500/maxLines 2 tagline
      final titleWidget = tester.widget<Text>(find.text('Welcome back'));
      expect(titleWidget.style?.fontSize, 18.0);
      expect(titleWidget.style?.fontWeight, FontWeight.w800);
      expect(titleWidget.maxLines, 2);
      expect(
        (titleWidget.style?.fontFamily ?? '')
            .toLowerCase()
            .replaceAll(' ', '')
            .contains('plusjakartasans'),
        isTrue,
      );
      expect(titleWidget.style?.color, const Color(0xFF0B1B33));

      final taglineWidget =
          tester.widget<Text>(find.text('Connect. Collaborate. Grow.'));
      expect(taglineWidget.style?.fontSize, 11.0);
      expect(taglineWidget.style?.fontWeight, FontWeight.w500);
      expect(taglineWidget.maxLines, 2);

      // Verify 48x48 scanner button with 22px icon + 48x48 avatar
      final scannerIcon =
          tester.widget<Icon>(find.byIcon(Icons.qr_code_scanner));
      expect(scannerIcon.size, 22.0);
      final actionSized48 = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((s) => s.width == 48.0 && s.height == 48.0)
          .length;
      expect(actionSized48, greaterThanOrEqualTo(2));

      // Switch live to DARK brightness -> switches to logoUrlDark & dark colors, keeps logoHeight 48
      state.updatePlatformBrightness(Brightness.dark);
      await tester.pump();

      images = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .toList();
      final darkLogo = images.firstWhere(
        (i) => i.imageUrl == 'https://efactor.tech/assets/images/dark_grid.png',
      );
      expect(darkLogo.height, 48.0);
      expect(
        images.any(
          (i) =>
              i.imageUrl == 'https://efactor.tech/assets/images/GRID_Logo.png',
        ),
        isFalse,
      );

      final darkTitle = tester.widget<Text>(find.text('Welcome back'));
      expect(darkTitle.style?.color, const Color(0xFFF8FAFC));

      // Verify synthesized stats cards use dark theme surface (#1a1f2e) instead of hardcoded white
      final statsSurfaceContainers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFF1A1F2E));
      expect(statsSurfaceContainers, isNotEmpty);

      // Verify dark gradient featureCard (#1e1b4b -> #1a1f2e) via Ink decoration
      final darkGradientCards = tester
          .widgetList<Ink>(find.byType(Ink))
          .where((ink) {
        final dec = ink.decoration;
        if (dec is! BoxDecoration) return false;
        final grad = dec.gradient;
        return grad is LinearGradient &&
            grad.colors.contains(const Color(0xFF1E1B4B)) &&
            grad.colors.contains(const Color(0xFF1A1F2E));
      });
      expect(darkGradientCards, isNotEmpty);

      // Narrow width (<320dp) -> logoHeight 44, globe 148x148
      tester.view.physicalSize = const Size(300, 900);
      await tester.pump();
      images = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .toList();
      expect(
        images
            .firstWhere((i) =>
                i.imageUrl ==
                'https://efactor.tech/assets/images/dark_grid.png')
            .height,
        44.0,
      );
      expect(
        images
            .firstWhere((i) =>
                i.imageUrl ==
                'https://efactor.tech/assets/images/grid-orbit-globe.png')
            .width,
        148.0,
      );

      // Medium width (650dp) -> logoHeight 52, globe 168x168
      tester.view.physicalSize = const Size(650, 900);
      await tester.pump();
      images = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .toList();
      expect(
        images
            .firstWhere((i) =>
                i.imageUrl ==
                'https://efactor.tech/assets/images/dark_grid.png')
            .height,
        52.0,
      );
      expect(
        images
            .firstWhere((i) =>
                i.imageUrl ==
                'https://efactor.tech/assets/images/grid-orbit-globe.png')
            .width,
        168.0,
      );
    });

    testWidgets(
        'Grid error/loading states respect appearanceDark and Retry invokes refreshHandler',
        (tester) async {
      final errorState = GridSduiState(
        buildThemeSchema(
          defaultMode: 'dark',
          rootComponentId: 'grid-error',
        ),
      );
      var refreshed = false;
      errorState.refreshHandler = () async {
        refreshed = true;
      };
      final errorRenderer = GridSduiRenderer(errorState);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => errorRenderer.buildRoot(context),
            ),
          ),
        ),
      );

      final title = tester.widget<Text>(find.text('Unable to load GRID'));
      expect(title.style?.color, const Color(0xFFF8FAFC));

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(refreshed, isTrue);

      final loadingState = GridSduiState(
        buildThemeSchema(
          defaultMode: 'dark',
          rootComponentId: 'grid-loading',
        ),
      );
      final loadingRenderer = GridSduiRenderer(loadingState);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => loadingRenderer.buildRoot(context),
            ),
          ),
        ),
      );
      expect(find.byType(SchemaIssueWidget), findsNothing);
    });

    test('GridGlobeMaskHelper detects opaque light square mattes vs transparent PNGs',
        () {
      const size = 64;
      Uint8List makeBuffer({
        required int cornerR,
        required int cornerG,
        required int cornerB,
        required int cornerA,
        required int centerR,
        required int centerG,
        required int centerB,
        required int centerA,
      }) {
        final bytes = Uint8List(size * size * 4);
        for (var i = 0; i < size * size; i++) {
          final off = i * 4;
          bytes[off] = cornerR;
          bytes[off + 1] = cornerG;
          bytes[off + 2] = cornerB;
          bytes[off + 3] = cornerA;
        }
        const mid = ((size ~/ 2) * size + (size ~/ 2)) * 4;
        bytes[mid] = centerR;
        bytes[mid + 1] = centerG;
        bytes[mid + 2] = centerB;
        bytes[mid + 3] = centerA;
        return bytes;
      }

      final opaqueLightSquare = makeBuffer(
        cornerR: 247,
        cornerG: 247,
        cornerB: 247,
        cornerA: 255,
        centerR: 25,
        centerG: 25,
        centerB: 25,
        centerA: 255,
      );
      expect(
        GridGlobeMaskHelper.shouldMaskOpaqueLightBackground(
          ByteData.sublistView(opaqueLightSquare),
          size,
          size,
        ),
        isTrue,
      );

      final transparentPng = makeBuffer(
        cornerR: 0,
        cornerG: 0,
        cornerB: 0,
        cornerA: 0,
        centerR: 25,
        centerG: 25,
        centerB: 25,
        centerA: 255,
      );
      expect(
        GridGlobeMaskHelper.shouldMaskOpaqueLightBackground(
          ByteData.sublistView(transparentPng),
          size,
          size,
        ),
        isFalse,
      );
    });
  });
}
