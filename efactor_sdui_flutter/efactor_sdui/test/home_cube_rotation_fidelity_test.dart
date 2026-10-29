import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_renderer.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';

void main() {
  Map<String, dynamic> createTestSchema({
    required List<Map<String, dynamic>> faces,
    Map<String, dynamic>? cubeGeometry,
    Map<String, dynamic>? cubeAnimation,
  }) {
    return <String, dynamic>{
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
      'uiRenderContract': <String, dynamic>{
        'cubeGeometry': cubeGeometry ??
            <String, dynamic>{
              'model': 'fourFaceBoxRotation',
              'rendererKey': 'fourFaceBoxRotation',
              'axis': 'y',
              'degreesPerFace': -90,
              'direction': 'counterclockwise',
              'perspectivePx': 800,
              'depthFormula': 'slotWidth',
              'halfDepthFormula': 'slotWidth / 2',
            },
        'cubeAnimation': cubeAnimation ??
            <String, dynamic>{
              'model': 'fourFaceBoxRotation',
              'durationMs': 16000,
              'holdRatio': 0.84,
              'transitionRatio': 0.16,
              'curve': 'ease-in-out-cubic',
            },
      },
      'components': <String, dynamic>{
        'test-cube': <String, dynamic>{
          'id': 'test-cube',
          'type': 'rotatingFaceCard',
          'layout': <String, dynamic>{
            'columnSpan': 1,
            'rowSpan': 1,
          },
          'dimensions': <String, dynamic>{
            'sizeFormula': 'slotWidth',
          },
          'faces': faces,
        },
      },
    };
  }

  testWidgets('Rotating cube renders with unclipped 3D boundary', (
    tester,
  ) async {
    final faces = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'face-0',
        'title': 'Face Zero',
        'appearance': <String, dynamic>{'backgroundColor': '#7c3aed'},
      },
      <String, dynamic>{
        'id': 'face-1',
        'title': 'Face One',
        'appearance': <String, dynamic>{'backgroundColor': '#0ea5e9'},
      },
    ];

    final schema = createTestSchema(faces: faces);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: Builder(
                builder: (context) =>
                    renderer.buildComponent(context, 'test-cube'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Front face is rendered cleanly
    expect(find.text('Face Zero'), findsOneWidget);

    // Verify the rotating cube stack has clipBehavior: Clip.none so 3D corners are not chopped
    final stacks = tester.widgetList<Stack>(find.byType(Stack));
    final unclippedStack = stacks.firstWhere(
      (s) => s.clipBehavior == Clip.none,
      orElse: () => throw StateError('No unclipped Stack found for 3D cube'),
    );
    expect(unclippedStack.clipBehavior, Clip.none,
        reason: 'Rotating cube Stack must be Clip.none for 3D extrusion');
  });

  testWidgets('4-face rotating card renders initial face cleanly', (tester) async {
    final faces = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'f0', 'title': 'Alpha', 'appearance': <String, dynamic>{'backgroundColor': '#7c3aed'}},
      <String, dynamic>{'id': 'f1', 'title': 'Beta', 'appearance': <String, dynamic>{'backgroundColor': '#0ea5e9'}},
      <String, dynamic>{'id': 'f2', 'title': 'Gamma', 'appearance': <String, dynamic>{'backgroundColor': '#22c55e'}},
      <String, dynamic>{'id': 'f3', 'title': 'Delta', 'appearance': <String, dynamic>{'backgroundColor': '#f59e0b'}},
    ];

    final schema = createTestSchema(faces: faces);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: Builder(
                builder: (context) =>
                    renderer.buildComponent(context, 'test-cube'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('Rotating cube transform uses negative perspective entry for convex protrusion', (tester) async {
    final faces = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'f0', 'title': 'Alpha', 'appearance': <String, dynamic>{'backgroundColor': '#7c3aed'}},
      <String, dynamic>{'id': 'f1', 'title': 'Beta', 'appearance': <String, dynamic>{'backgroundColor': '#0ea5e9'}},
    ];

    final schema = createTestSchema(faces: faces);
    final renderer = HomeSduiRenderer(
      HomeSduiState(schema: schema, accessToken: 'test-token'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: Builder(
                builder: (context) =>
                    renderer.buildComponent(context, 'test-cube'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final transforms = tester.widgetList<Transform>(find.byType(Transform));
    final cubeTransforms = transforms.where((t) => t.transform.entry(3, 2) != 0).toList();
    expect(cubeTransforms, isNotEmpty,
        reason: 'At least one 3D face transform with perspective must be present');
    final hasConvexFrontTransform = cubeTransforms.any((t) => t.transform.entry(3, 2) < 0);
    expect(hasConvexFrontTransform, isTrue,
        reason: 'Front face perspective entry (3, 2) must be negative so near edges expand outward (convex exterior)');
  });
}
