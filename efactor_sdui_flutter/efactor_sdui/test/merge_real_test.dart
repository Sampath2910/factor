import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/data/schema_repository.dart';

void main() {
  test('merge real page 3 and page 4', () async {
    final file = File('test/test_schemas_cache.json');
    final allPages = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final p3 = allPages['3'] as Map<String, dynamic>;
    final p4 = allPages['4'] as Map<String, dynamic>;

    SchemaRepository.ensurePlaceholderSlides(p3);
    SchemaRepository.ensurePlaceholderSlides(p4);

    final merged = SchemaRepository.mergeDevicePageSchema(p3, p4);

    print('Merged pages count: ${(merged['pages'] as List?)?.length}');
    for (final p in merged['pages']) {
      print('  p: id=${p['id']}, pageNo=${p['pageNo']}, controlIds=${(p['controlIds'] as List?)?.length}');
    }

    print('\nMerged controls count: ${(merged['controls'] as List?)?.length}');

    // Find page_slider in merged['ui']
    Map? findSlider(dynamic node) {
      if (node is! Map) return null;
      if (node['id'] == 'page_slider') return node;
      final children = node['children'];
      if (children is List) {
        for (final c in children) {
          final found = findSlider(c);
          if (found != null) return found;
        }
      }
      return null;
    }

    final slider = findSlider(merged['ui']);
    if (slider != null) {
      print('\nMerged slider children count: ${(slider['children'] as List).length}');
      for (final slide in slider['children']) {
        final id = slide['id'];
        final pNo = slide['properties']?['pageNo'];
        final children = (slide['children'] as List?)?.map((c) => c['id']).toList();
        print('  slide id=$id, pNo=$pNo, children=$children');
      }
    }

    void printAllNodes(dynamic node, String indent) {
      if (node is! Map) return;
      print('$indent${node['id']} (${node['type']}) props: ${node['properties']}');
      final children = node['children'];
      if (children is List) {
        for (final c in children) printAllNodes(c, '$indent  ');
      }
    }

    print('\nMerged UI top-level tree:');
    printAllNodes(merged['ui']?['widgetTree'], '  ');
  });
}
