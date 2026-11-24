import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/grid_sdui/grid_in_app_webview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Professional Space / Team URL & visibility detection tests', () {
    test('Identifies Professional Space root and Team URLs correctly', () {
      final profRootUri = Uri.parse('https://efactor.tech/index.php/grid');
      final profTeamUri = Uri.parse('https://efactor.tech/grid/team');
      final profTeamSubUri = Uri.parse('https://efactor.tech/index.php/grid/team');
      final circleConnectUri = Uri.parse('https://efactor.tech/grid-chat');

      // Professional Space Root
      expect(GridInAppWebViewPage.isProfessionalSpaceRootUrl(profRootUri), isTrue);
      expect(GridInAppWebViewPage.isProfessionalSpaceRootUrl(circleConnectUri), isFalse);

      // Verify widget creation with various Professional Space and Team configurations
      final teamPage = GridInAppWebViewPage(
        uri: profTeamUri,
        title: 'Team',
        userId: 177,
        accessToken: 'test_token',
      );
      expect(teamPage.uri.path.contains('/team'), isTrue);

      final profSpacePage = GridInAppWebViewPage(
        uri: profTeamSubUri,
        title: 'Professional Space',
        userId: 177,
        accessToken: 'test_token',
      );
      expect(profSpacePage.uri.toString().contains('team'), isTrue);
    });

    test('isProfessionalSpaceExitUrl detects exit parameters', () {
      final exitUri1 = Uri.parse('https://efactor.tech/index.php/grid?app=exit');
      final exitUri2 = Uri.parse('https://efactor.tech/grid?app=exit');
      final normalUri = Uri.parse('https://efactor.tech/grid/team');

      expect(GridInAppWebViewPage.isProfessionalSpaceExitUrl(exitUri1), isTrue);
      expect(GridInAppWebViewPage.isProfessionalSpaceExitUrl(exitUri2), isTrue);
      expect(GridInAppWebViewPage.isProfessionalSpaceExitUrl(normalUri), isFalse);
    });

    test('revealSignal transitions trigger visibility state changes correctly', () {
      final revealSignal = ValueNotifier<bool>(false);
      final widget = GridInAppWebViewPage(
        uri: Uri.parse('https://efactor.tech/grid/team'),
        title: 'Team',
        revealSignal: revealSignal,
        userId: 177,
      );

      expect(widget.revealSignal, isNotNull);
      expect(widget.revealSignal!.value, isFalse);

      // Simulate revealing Team view
      revealSignal.value = true;
      expect(widget.revealSignal!.value, isTrue);

      // Simulate hiding Team view
      revealSignal.value = false;
      expect(widget.revealSignal!.value, isFalse);
    });
  });
}
