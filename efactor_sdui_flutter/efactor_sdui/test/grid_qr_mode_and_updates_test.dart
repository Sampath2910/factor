import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';

void main() {
  setUp(() {
    GridSduiState.persistedSelectedQrMode = null;
  });

  tearDown(() {
    GridSduiState.persistedSelectedQrMode = null;
  });

  group('GRID Share Profile QR Mode Persistence', () {
    final templateSchema = <String, dynamic>{
      'components': <String, dynamic>{
        'grid-share-qr': <String, dynamic>{
          'id': 'grid-share-qr',
          'type': 'shareQrCard',
          'selectedMode': 'professional',
          'modes': [
            {'id': 'professional', 'label': 'Professional'},
            {'id': 'circle', 'label': 'Circle'},
          ],
          'qrPayload': 'https://efactor.tech/index.php/grid/connect?mode=professional&grid_id=123&user_id=177',
          'qrImageUrlsByMode': {
            'professional': 'https://efactor.tech/v8/qr_image.php?data=https%3A%2F%2Fefactor.tech%2Findex.php%2Fgrid%2Fconnect%3Fmode%3Dprofessional%26grid_id%3D123%26user_id%3D177&size=200&mode=professional',
            'circle': 'https://efactor.tech/v8/qr_image.php?data=https%3A%2F%2Fefactor.tech%2Findex.php%2Fgrid-chat%2Fconnect%3Fmode%3Dcircle%26grid_id%3D123%26user_id%3D177&size=200&mode=circle',
          },
        },
      },
      'actions': <String, dynamic>{
        'grid-select-qr-mode': <String, dynamic>{
          'type': 'host-action',
          'actionId': 'select-grid-qr-mode',
        },
      },
    };

    test('initial state defaults to professional mode', () {
      final state = GridSduiState(Map<String, dynamic>.from(templateSchema));
      expect(state.selectedQrMode, 'professional');
      expect(
        state.qrImageUrlForMode(state.selectedQrMode),
        contains('mode=professional'),
      );
    });

    test('dispatching select-grid-qr-mode circle updates mode and image', () async {
      final state = GridSduiState(Map<String, dynamic>.from(templateSchema));
      await state.dispatch(
        'grid-select-qr-mode',
        extra: <String, dynamic>{'mode': 'circle'},
      );

      expect(state.selectedQrMode, 'circle');
      expect(
        state.qrImageUrlForMode(state.selectedQrMode),
        contains('grid-chat%2Fconnect%3Fmode%3Dcircle'),
      );
      expect(
        state.qrPayloadForMode(state.selectedQrMode),
        'https://efactor.tech/index.php/grid-chat/connect?mode=circle&grid_id=123&user_id=177',
      );
    });

    test('new schema refresh with default professional preserves user circle selection', () async {
      final state1 = GridSduiState(Map<String, dynamic>.from(templateSchema));
      await state1.dispatch(
        'grid-select-qr-mode',
        extra: <String, dynamic>{'mode': 'circle'},
      );
      expect(state1.selectedQrMode, 'circle');

      // Simulate network refresh arriving with backend re-defaulting selectedMode to professional
      final refreshedSchema = Map<String, dynamic>.from(templateSchema);
      final state2 = GridSduiState(refreshedSchema);

      expect(state2.selectedQrMode, 'circle');
      expect(
        state2.qrImageUrlForMode(state2.selectedQrMode),
        contains('grid-chat%2Fconnect%3Fmode%3Dcircle'),
      );
    });

    test('user can switch back to professional and it persists', () async {
      final state = GridSduiState(Map<String, dynamic>.from(templateSchema));
      await state.dispatch(
        'grid-select-qr-mode',
        extra: <String, dynamic>{'mode': 'circle'},
      );
      expect(state.selectedQrMode, 'circle');

      await state.dispatch(
        'grid-select-qr-mode',
        extra: <String, dynamic>{'mode': 'professional'},
      );
      expect(state.selectedQrMode, 'professional');
      expect(
        state.qrImageUrlForMode(state.selectedQrMode),
        contains('mode=professional'),
      );
    });
  });

  group('GRID Updates Dual-Space Support', () {
    final updatesSchema = <String, dynamic>{
      'components': <String, dynamic>{
        'grid-explore-section': <String, dynamic>{
          'id': 'grid-explore-section',
          'type': 'section',
          'title': 'Updates',
          'filters': [
            {'id': 'professional', 'label': 'Professional', 'selected': true},
            {'id': 'circle', 'label': 'Chat', 'selected': false},
          ],
          'children': ['grid-explore-row'],
        },
        'grid-explore-row': <String, dynamic>{
          'id': 'grid-explore-row',
          'type': 'responsiveGrid',
          'children': ['msg-prof-1', 'msg-circle-1'],
        },
        'msg-prof-1': <String, dynamic>{
          'id': 'msg-prof-1',
          'type': 'featureCard',
          'space': 'professional',
          'title': 'New Inquiry',
          'subtitle': 'Looking for Flutter devs',
          'unread': true,
        },
        'msg-circle-1': <String, dynamic>{
          'id': 'msg-circle-1',
          'type': 'featureCard',
          'space': 'circle',
          'title': 'Coffee Meetup',
          'subtitle': 'Join our weekend circle chat',
          'unread': false,
        },
      },
    };

    test('initial filter is professional from schema filters', () {
      final state = GridSduiState(Map<String, dynamic>.from(updatesSchema));
      expect(state.selectedFilter('grid-explore-section'), 'professional');
    });

    test('setSelectedFilter persists filter selection across refresh', () {
      final state1 = GridSduiState(Map<String, dynamic>.from(updatesSchema));
      state1.setSelectedFilter('grid-explore-section', 'circle');
      expect(state1.selectedFilter('grid-explore-section'), 'circle');

      // On new schema instance
      final state2 = GridSduiState(Map<String, dynamic>.from(updatesSchema));
      expect(state2.selectedFilter('grid-explore-section'), 'circle');
    });

    test('content exploring items are synthesized into grid-explore-row', () {
      final envelope = <String, dynamic>{
        'components': <String, dynamic>{
          'grid-explore-row': <String, dynamic>{
            'id': 'grid-explore-row',
            'children': <String>[],
          },
        },
        'content': <String, dynamic>{
          'exploring': <String, dynamic>{
            'items': [
              {
                'id': 'chat-101',
                'space': 'circle',
                'title': 'Circle Chat 101',
                'subtitle': 'Hello from circle connect',
                'unread': true,
                'actionId': 'grid-open-circle-connect',
                'url': 'https://efactor.tech/index.php/grid-chat',
              },
            ],
          },
        },
      };

      final state = GridSduiState(envelope);
      final row = state.component('grid-explore-row');
      expect((row?['children'] as List).contains('chat-101'), isTrue);

      final comp = state.component('chat-101');
      expect(comp, isNotNull);
      expect(comp?['space'], 'circle');
      expect(comp?['title'], 'Circle Chat 101');
      expect(comp?['unread'], isTrue);
    });
  });
}
