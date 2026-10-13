import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';

void main() {
  test('IoT Search Dynamic SDUI Execution and Filtering', () async {
    final res = await http.get(Uri.parse(
      'https://efactor.tech/v8/iot_api_creation.php?action=get_iot_schema&access_token=test123',
    ));
    expect(res.statusCode, 200);
    final data = jsonDecode(res.body);
    final schema = data['schema'] as Map<String, dynamic>;

    final state = IotSduiState(
      schema: schema,
      accessToken: 'test123',
    );

    expect(state.isSearchVisible, false);
    expect(state.searchQuery, '');

    final header = state.page['header'] as Map<String, dynamic>;
    final searchBtn = header['search']['button'] as Map<String, dynamic>;
    final tapAction = searchBtn['onTap'] as Map<String, dynamic>;

    expect(state.canExecuteAction(tapAction), true);

    await state.executeAction(tapAction);
    expect(state.isSearchVisible, true);

    state.setSearchQuery('Smart Fan');
    expect(state.searchQuery, 'Smart Fan');

    await state.executeAction(tapAction);
    expect(state.isSearchVisible, false);
    expect(state.searchQuery, '');
  });
}
