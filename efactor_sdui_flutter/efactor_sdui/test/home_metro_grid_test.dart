import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/home_sdui/home_metro_grid.dart';

void main() {
  test('metro Home grid keeps 6-column schema coordinates', () {
    final placed = placeHomeMetroGrid(
      columns: 6,
      clampColumnSpan: true,
      items: const <HomeMetroItem>[
        HomeMetroItem(
          id: 'prime',
          columnSpan: 2,
          rowSpan: 2,
          columnStart: 1,
          rowStart: 1,
        ),
        HomeMetroItem(
          id: 'live',
          columnSpan: 2,
          rowSpan: 1,
          columnStart: 3,
          rowStart: 1,
        ),
        HomeMetroItem(
          id: 'mobile',
          columnSpan: 2,
          rowSpan: 1,
          columnStart: 5,
          rowStart: 1,
        ),
        HomeMetroItem(
          id: 'rewards',
          columnSpan: 1,
          rowSpan: 1,
          columnStart: 3,
          rowStart: 2,
        ),
        HomeMetroItem(
          id: 'deals',
          columnSpan: 1,
          rowSpan: 1,
          columnStart: 4,
          rowStart: 2,
        ),
        HomeMetroItem(
          id: 'elec',
          columnSpan: 2,
          rowSpan: 1,
          columnStart: 5,
          rowStart: 2,
        ),
        HomeMetroItem(
          id: 'grid',
          columnSpan: 6,
          rowSpan: 1,
          columnStart: 1,
          rowStart: 4,
        ),
      ],
    );

    expect(placed.map((item) => item.id).toList(), <String>[
      'prime',
      'live',
      'mobile',
      'rewards',
      'deals',
      'elec',
      'grid',
    ]);
    expect(placed.first.column, 0);
    expect(placed.first.columnSpan, 2);
    expect(placed.first.rowSpan, 2);
    expect(placed[1].id, 'live');
    expect(placed[1].column, 2);
    expect(placed[2].column, 4);
    expect(placed[3].column, 2);
    expect(placed[3].row, 1);
    expect(placed.last.id, 'grid');
    expect(placed.last.columnSpan, 6);
    expect(placed.last.row, 3);
  });

  test('metro items without coordinates still pack in order', () {
    final placed = placeHomeMetroGrid(
      columns: 6,
      clampColumnSpan: true,
      items: const <HomeMetroItem>[
        HomeMetroItem(id: 'a', columnSpan: 2, rowSpan: 2),
        HomeMetroItem(id: 'b', columnSpan: 2, rowSpan: 1),
        HomeMetroItem(id: 'c', columnSpan: 2, rowSpan: 1),
      ],
    );

    expect(placed[0].column, 0);
    expect(placed[1].column, 2);
    expect(placed[2].column, 4);
  });

  test('metro items never overlap or overflow when rendered in 3 columns', () {
    final placed = placeHomeMetroGrid(
      columns: 3,
      clampColumnSpan: true,
      items: const <HomeMetroItem>[
        HomeMetroItem(
          id: 'prime',
          columnSpan: 2,
          rowSpan: 2,
          columnStart: 1,
          rowStart: 1,
        ),
        HomeMetroItem(
          id: 'live',
          columnSpan: 2,
          rowSpan: 1,
          columnStart: 3,
          rowStart: 1,
        ),
        HomeMetroItem(
          id: 'mobile',
          columnSpan: 2,
          rowSpan: 1,
          columnStart: 5,
          rowStart: 1,
        ),
        HomeMetroItem(
          id: 'rewards',
          columnSpan: 1,
          rowSpan: 1,
          columnStart: 3,
          rowStart: 2,
        ),
      ],
    );

    // Verify all items are placed
    expect(placed.length, 4);

    // Verify no item overflows beyond 3 columns
    for (final p in placed) {
      expect(p.column + p.columnSpan, lessThanOrEqualTo(3));
      expect(p.column, greaterThanOrEqualTo(0));
    }

    // Verify no two items occupy the same grid slot
    final occupied = <String>{};
    for (final p in placed) {
      for (var r = p.row; r < p.row + p.rowSpan; r++) {
        for (var c = p.column; c < p.column + p.columnSpan; c++) {
          final key = '$r:$c';
          expect(occupied.contains(key), isFalse,
              reason: 'Slot $key occupied by multiple items including ${p.id}');
          occupied.add(key);
        }
      }
    }
  });
}
