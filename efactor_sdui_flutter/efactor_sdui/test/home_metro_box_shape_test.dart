import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets('omitted borderRadius uses the theme card radius', (tester) async {
    final schema = _radiusSchema(borderRadius: null, tokenRadius: 16);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.buildComponent(context, 'tile'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_clipRadii(tester), contains(16));
  });

  testWidgets('explicit borderRadius 0 produces square corners (0.0)', (tester) async {
    final schema = _radiusSchema(borderRadius: 0, tokenRadius: 16);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.buildComponent(context, 'tile'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_clipRadii(tester), contains(0.0));
    expect(_clipRadii(tester), isNot(contains(16)));
  });

  testWidgets('explicit borderRadius overrides the theme radius', (tester) async {
    final schema = _radiusSchema(borderRadius: 12, tokenRadius: 16);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.buildComponent(context, 'tile'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_clipRadii(tester), contains(12));
    expect(_clipRadii(tester), isNot(contains(16)));
  });

  testWidgets('declared rowHeight sizes the metro cell instead of slotWidth', (
    tester,
  ) async {
    final schema = <String, dynamic>{
      'designTokens': <String, dynamic>{
        'colors': <String, dynamic>{
          'surface': '#151b2e',
          'textPrimary': '#ffffff',
          'textSecondary': '#94a3b8',
          'welcomeText': '#ffffff',
        },
        'radius': <String, dynamic>{'card': 16.0},
        'spacing': <String, dynamic>{'sm': 8.0, 'xs': 4.0, 'xxs': 2.0},
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
          'pageTitle': <String, dynamic>{'fontSize': 18.0},
          'statValue': <String, dynamic>{'fontSize': 14.0, 'fontWeight': 700},
        },
      },
      'uiRenderContract': <String, dynamic>{
        'cubeGeometry': <String, dynamic>{'sizeFormula': 'slotWidth'},
      },
      'components': <String, dynamic>{
        'home-grid': <String, dynamic>{
          'id': 'home-grid',
          'type': 'responsiveGrid',
          'style': 'metroMosaic',
          'layout': <String, dynamic>{
            'type': 'metroGrid',
            'columns': 3,
            'columnGap': 6.0,
            'rowGap': 6.0,
            'rowHeight': 96.0,
            'minRowHeight': 96.0,
          },
          'children': <dynamic>['tile-1x1'],
        },
        'tile-1x1': <String, dynamic>{
          'id': 'tile-1x1',
          'type': 'rotatingFaceCard',
          'layout': <String, dynamic>{'columnSpan': 1, 'rowSpan': 1},
          'faces': <dynamic>[
            <String, dynamic>{
              'id': 'face-0',
              'title': 'Row',
              'appearance': <String, dynamic>{'backgroundColor': '#7c3aed'},
            },
          ],
        },
      },
    };

    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 375,
            child: Builder(
              builder: (context) =>
                  renderer.buildComponent(context, 'home-grid'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byWidgetPredicate((widget) {
      return widget is Positioned &&
          widget.width != null &&
          widget.height != null &&
          (widget.width! - 121.0).abs() < 0.1 &&
          (widget.height! - 96.0).abs() < 0.1;
    });
    expect(tile, findsOneWidget);
  });

  testWidgets('a zero-radius tile paints a square corner', (tester) async {
    final schema = _radiusSchema(borderRadius: 0, tokenRadius: 16);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: Center(
            child: RepaintBoundary(
              key: const Key('tile-shot'),
              child: SizedBox(
                width: 160,
                height: 160,
                child: Builder(
                  builder: (context) => renderer.buildComponent(context, 'tile'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('tile-shot')),
    );
    final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
    final bytes = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int at(int x, int y) {
      final offset = (y * image!.width + x) * 4;
      return bytes!.getUint8(offset);
    }

    // Corner of the 160 tile must be painted with the purple face (sharp square), not clipped.
    expect(at(2, 2), greaterThan(80), reason: 'top-left corner is painted as a sharp square');
    expect(at(80, 80), greaterThan(80), reason: 'tile center should be painted');
  });

  testWidgets(
    'backend grid.rowHeightDp and responsiveLayouts override legacy 96dp component layout',
    (tester) async {
      final schema = <String, dynamic>{
        'designTokens': <String, dynamic>{
          'colors': <String, dynamic>{
            'surface': '#151b2e',
            'textPrimary': '#ffffff',
            'textSecondary': '#94a3b8',
            'welcomeText': '#ffffff',
          },
          'radius': <String, dynamic>{'card': 16.0},
          'spacing': <String, dynamic>{'sm': 8.0, 'xs': 4.0, 'xxs': 2.0},
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
            'pageTitle': <String, dynamic>{'fontSize': 18.0},
            'statValue': <String, dynamic>{
              'fontSize': 14.0,
              'fontWeight': 700,
            },
          },
        },
        'grid': <String, dynamic>{
          'rowHeightDp': 117.0,
          'responsiveLayouts': <String, dynamic>{
            'compact': <String, dynamic>{
              'columns': 3,
              'rowHeight': 117.0,
              'minRowHeight': 117.0,
            },
          },
        },
        'components': <String, dynamic>{
          'home-grid': <String, dynamic>{
            'id': 'home-grid',
            'type': 'responsiveGrid',
            'style': 'metroMosaic',
            // Stale component template has legacy 96dp:
            'layout': <String, dynamic>{
              'type': 'metroGrid',
              'columns': 3,
              'columnGap': 4.0,
              'rowGap': 4.0,
              'rowHeight': 96.0,
              'minRowHeight': 96.0,
            },
            'layouts': <String, dynamic>{
              'compact': <String, dynamic>{
                'columns': 3,
                'columnGap': 4.0,
                'rowGap': 4.0,
                'rowHeight': 96.0,
                'minRowHeight': 96.0,
              },
            },
            'children': <dynamic>['tile-1x1'],
          },
          'tile-1x1': <String, dynamic>{
            'id': 'tile-1x1',
            'type': 'rotatingFaceCard',
            'layout': <String, dynamic>{'columnSpan': 1, 'rowSpan': 1},
            'faces': <dynamic>[
              <String, dynamic>{
                'id': 'face-0',
                'title': 'Connect',
                'appearance': <String, dynamic>{'backgroundColor': '#f97316'},
              },
            ],
          },
        },
      };

      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final renderer = HomeSduiRenderer(
        HomeSduiState(schema: schema, accessToken: 'test-token'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 375,
              child: Builder(
                builder: (context) =>
                    renderer.buildComponent(context, 'home-grid'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // tile height must match the updated schema.grid rowHeight (117.0), NOT legacy 96.0!
      final tile = find.byWidgetPredicate((widget) {
        return widget is Positioned &&
            widget.height != null &&
            (widget.height! - 117.0).abs() < 0.1;
      });
      expect(tile, findsOneWidget, reason: 'tile should be sized with schema rowHeight 117.0');
    },
  );

  testWidgets(
    'tile with omitted borderRadius uses theme cardBorderRadius 16',
    (tester) async {
      final schema = _radiusSchema(borderRadius: null, tokenRadius: 16);
      final renderer = HomeSduiRenderer(
        HomeSduiState(schema: schema, accessToken: 'test-token'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => renderer.buildComponent(context, 'tile'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final radii = _clipRadii(tester);
      expect(radii, isNotEmpty);
      expect(radii, everyElement(equals(16.0)));
    },
  );

  testWidgets(
    'tiles with borderRadius: 0 remain squares even if theme.cardBorderRadius is 20 (like User 770)',
    (tester) async {
      final schema = _radiusSchema(borderRadius: 0, tokenRadius: 20);
      final renderer = HomeSduiRenderer(HomeSduiState(schema: schema, accessToken: 'test-token'));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => renderer.buildComponent(context, 'tile'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final radii = _clipRadii(tester);
      expect(radii, contains(0.0), reason: 'tile with borderRadius 0 must have radius 0.0 despite theme radius 20');
    },
  );

  testWidgets(
    'squares with curves: renders 1:1 square box cell with curved border radius dynamically from schema',
    (tester) async {
      final schema = <String, dynamic>{
        'designTokens': <String, dynamic>{
          'colors': <String, dynamic>{
            'surface': '#151b2e',
            'textPrimary': '#ffffff',
            'textSecondary': '#94a3b8',
            'welcomeText': '#ffffff',
          },
          'radius': <String, dynamic>{'card': 16.0},
          'spacing': <String, dynamic>{'sm': 8.0, 'xs': 4.0, 'xxs': 2.0},
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
            'pageTitle': <String, dynamic>{'fontSize': 18.0},
            'statValue': <String, dynamic>{'fontSize': 14.0, 'fontWeight': 700},
          },
        },
        'uiRenderContract': <String, dynamic>{
          'cubeGeometry': <String, dynamic>{
            'sizeFormula': 'slotWidth',
          },
        },
        'meta': <String, dynamic>{
          'layoutSnapshot': <String, dynamic>{
            'theme': <String, dynamic>{
              'squareTiles': true,
              'cardBorderRadius': 16.0, // Curves requested in theme
            },
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
            'children': <dynamic>['curved-square-tile'],
          },
          'curved-square-tile': <String, dynamic>{
            'id': 'curved-square-tile',
            'type': 'rotatingFaceCard',
            'layout': <String, dynamic>{
              'columnSpan': 1,
              'rowSpan': 1,
            },
            'appearance': <String, dynamic>{
              'borderRadius': 16.0, // Explicit curve override
            },
            'faces': <dynamic>[
              <String, dynamic>{
                'id': 'face-0',
                'title': 'Curved Square',
                'appearance': <String, dynamic>{
                  'backgroundColor': '#7c3aed',
                  'borderRadius': 16.0,
                },
              },
            ],
          },
        },
      };

      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final renderer = HomeSduiRenderer(
        HomeSduiState(schema: schema, accessToken: 'test-token'),
      );
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

      // 1. Verify 1:1 square box geometry:
      final tileFinder = find.byWidgetPredicate((widget) {
        if (widget is Positioned && widget.width != null && widget.height != null) {
          return (widget.width! - 121.0).abs() < 0.1 && (widget.height! - 121.0).abs() < 0.1;
        }
        return false;
      });
      expect(tileFinder, findsOneWidget, reason: 'Tile must be a 1:1 square (width == height == 121.0)');

      // 2. Verify curves:
      final radii = _clipRadii(tester);
      expect(radii, contains(16.0), reason: 'Tile and faces must have 16.0dp curved corners');
    },
  );
}

Map<String, dynamic> _radiusSchema({
  num? borderRadius,
  required num tokenRadius,
}) {
  return <String, dynamic>{
    'designTokens': <String, dynamic>{
      'colors': <String, dynamic>{
        'surface': '#151b2e',
        'textPrimary': '#ffffff',
        'textSecondary': '#94a3b8',
        'welcomeText': '#ffffff',
      },
      'radius': <String, dynamic>{'card': tokenRadius},
      'spacing': <String, dynamic>{'sm': 8.0, 'xs': 4.0, 'xxs': 2.0},
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
        'pageTitle': <String, dynamic>{'fontSize': 18.0},
        'statValue': <String, dynamic>{'fontSize': 14.0, 'fontWeight': 700},
      },
    },
    'meta': <String, dynamic>{
      'layoutSnapshot': <String, dynamic>{
        'theme': <String, dynamic>{'cardBorderRadius': tokenRadius},
      },
    },
    'componentPresets': <String, dynamic>{
      'home-tile': <String, dynamic>{
        'type': 'rotatingFaceCard',
        'appearance': <String, dynamic>{'radiusToken': 'radius.card'},
      },
    },
    'components': <String, dynamic>{
      'tile': <String, dynamic>{
        'id': 'tile',
        'presetId': 'home-tile',
        if (borderRadius != null)
          'appearance': <String, dynamic>{
            'borderRadius': borderRadius,
            'style': 'metroTile',
          },
        'faces': <dynamic>[
          <String, dynamic>{
            'id': 'face-0',
            'title': 'Online',
            'appearance': <String, dynamic>{
              'backgroundColor': '#7c3aed',
              if (borderRadius != null) 'borderRadius': borderRadius,
              'style': 'startTile',
            },
          },
        ],
      },
    },
  };
}

List<double> _clipRadii(WidgetTester tester) {
  final radii = <double>[];
  for (final element in find.byType(ClipRRect).evaluate()) {
    final radius = (element.widget as ClipRRect).borderRadius;
    if (radius is BorderRadius) radii.add(radius.topLeft.x);
  }
  return radii;
}
