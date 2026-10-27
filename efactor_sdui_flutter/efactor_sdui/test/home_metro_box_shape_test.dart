import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_renderer.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';

void main() {
  testWidgets('metroGrid produces 1:1 square box cells based on slotWidth', (tester) async {
    final schema = <String, dynamic>{
      'designTokens': <String, dynamic>{
        'colors': <String, dynamic>{
          'surface': '#151b2e',
          'textPrimary': '#ffffff',
          'textSecondary': '#94a3b8',
          'welcomeText': '#ffffff',
        },
        'radius': <String, dynamic>{
          'card': 16.0,
        },
        'spacing': <String, dynamic>{
          'sm': 8.0,
          'xs': 4.0,
          'xxs': 2.0,
        },
        'typography': <String, dynamic>{
          'cardTitle': <String, dynamic>{
            'fontSize': 12.0,
            'fontWeight': 800,
            'maxLines': 1,
            'overflow': 'clip',
          },
          'cardSubtitle': <String, dynamic>{
            'fontSize': 9.0,
            'fontWeight': 700,
            'maxLines': 1,
            'overflow': 'clip',
          },
          'pageTitle': <String, dynamic>{
            'fontSize': 18.0,
          },
          'statValue': <String, dynamic>{
            'fontSize': 14.0,
            'fontWeight': 700,
          },
        },
      },
      'uiRenderContract': <String, dynamic>{
        'cubeGeometry': <String, dynamic>{
          'sizeFormula': 'slotWidth',
        },
      },
      'components': <String, dynamic>{
        'home-grid': <String, dynamic>{
          'id': 'home-grid',
          'type': 'responsiveGrid',
          'layout': <String, dynamic>{
            'type': 'metroGrid',
            'columns': 3,
            'columnGap': 6.0,
            'rowGap': 6.0,
            'sizeFormula': 'slotWidth',
          },
          'layouts': <String, dynamic>{
            'compact': <String, dynamic>{
              'columns': 3,
              'columnGap': 6.0,
              'rowGap': 6.0,
              'sizeFormula': 'slotWidth',
            },
          },
          'children': <dynamic>['tile-1x1', 'tile-2x2'],
        },
        'tile-1x1': <String, dynamic>{
          'id': 'tile-1x1',
          'type': 'rotatingFaceCard',
          'layout': <String, dynamic>{
            'columnSpan': 1,
            'rowSpan': 1,
          },
          'dimensions': <String, dynamic>{
            'sizeFormula': 'slotWidth',
          },
          'faces': <dynamic>[
            <String, dynamic>{
              'id': 'face-0',
              'title': 'Test 1x1',
              'appearance': <String, dynamic>{
                'backgroundColor': '#7c3aed',
              },
            },
          ],
        },
        'tile-2x2': <String, dynamic>{
          'id': 'tile-2x2',
          'type': 'rotatingFaceCard',
          'layout': <String, dynamic>{
            'columnSpan': 2,
            'rowSpan': 2,
          },
          'dimensions': <String, dynamic>{
            'sizeFormula': 'slotWidth',
          },
          'faces': <dynamic>[
            <String, dynamic>{
              'id': 'face-0',
              'title': 'Test 2x2',
              'appearance': <String, dynamic>{
                'backgroundColor': '#2563eb',
              },
            },
          ],
        },
      },
    };

    final state = HomeSduiState(schema: schema, accessToken: 'test-token');
    final renderer = HomeSduiRenderer(state);

    // Set a known screen viewport width (e.g. 375 width)
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 375,
            child: Builder(
              builder: (context) => renderer.buildComponent(context, 'home-grid'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Available width = 375.
    // 3 columns, 2 gaps of 6 = 12.
    // cellWidth = (375 - 12) / 3 = 363 / 3 = 121.0.
    final tile1Finder = find.byWidgetPredicate((widget) {
      if (widget is Positioned && widget.width != null && widget.height != null) {
        // Find the 1x1 tile
        return (widget.width! - 121.0).abs() < 0.1 && (widget.height! - 121.0).abs() < 0.1;
      }
      return false;
    });

    expect(tile1Finder, findsOneWidget, reason: '1x1 tile must have width == height == cellWidth (121.0)');

    // 2x2 tile: width = 2 * 121 + 6 = 248.0, height = 2 * 121 + 6 = 248.0
    final tile2Finder = find.byWidgetPredicate((widget) {
      if (widget is Positioned && widget.width != null && widget.height != null) {
        return (widget.width! - 248.0).abs() < 0.1 && (widget.height! - 248.0).abs() < 0.1;
      }
      return false;
    });

    expect(tile2Finder, findsOneWidget, reason: '2x2 tile must have width == height == 248.0 (perfect square)');
  });

  testWidgets('tile respects schema titleMaxLines and borderRadius dynamically', (tester) async {
    final schema = <String, dynamic>{
      'designTokens': <String, dynamic>{
        'colors': <String, dynamic>{
          'surface': '#151b2e',
          'textPrimary': '#ffffff',
          'textSecondary': '#94a3b8',
          'welcomeText': '#ffffff',
        },
        'radius': <String, dynamic>{
          'card': 24.0, // Tests that it is not clamped to 16.0 or 20.0
        },
        'spacing': <String, dynamic>{
          'sm': 8.0,
          'xs': 4.0,
          'xxs': 2.0,
        },
        'typography': <String, dynamic>{
          'cardTitle': <String, dynamic>{
            'fontSize': 12.0,
            'fontWeight': 800,
            'maxLines': 1,
            'overflow': 'ellipsis',
          },
          'cardSubtitle': <String, dynamic>{
            'fontSize': 9.0,
            'fontWeight': 700,
            'maxLines': 1,
            'overflow': 'ellipsis',
          },
          'pageTitle': <String, dynamic>{
            'fontSize': 18.0,
          },
          'statValue': <String, dynamic>{
            'fontSize': 14.0,
            'fontWeight': 700,
          },
        },
      },
      'components': <String, dynamic>{
        'custom-tile': <String, dynamic>{
          'id': 'custom-tile',
          'type': 'rotatingFaceCard',
          'titleMaxLines': 3,
          'faces': <dynamic>[
            <String, dynamic>{
              'id': 'face-0',
              'title': 'Featured Applications',
              'titleMaxLines': 3,
              'appearance': <String, dynamic>{
                'backgroundColor': '#7c3aed',
              },
            },
          ],
        },
      },
    };

    final state = HomeSduiState(schema: schema, accessToken: 'test-token');
    final renderer = HomeSduiRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.buildComponent(context, 'custom-tile'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final textWidget = tester.widget<Text>(find.text('Featured Applications'));
    expect(textWidget.maxLines, 3, reason: 'titleMaxLines should be taken dynamically from schema');

    // Verify ClipRRect has border radius 24.0 from tokens, not clamped
    final clipFinder = find.byWidgetPredicate((widget) {
      if (widget is ClipRRect && widget.borderRadius is BorderRadius) {
        final br = widget.borderRadius as BorderRadius;
        return br.topLeft.x == 24.0;
      }
      return false;
    });
    expect(clipFinder, findsWidgets, reason: 'Border radius should be 24.0 dynamically from designTokens without arbitrary clamping');
  });
}
