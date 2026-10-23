class HomeMetroItem {
  const HomeMetroItem({
    required this.id,
    required this.columnSpan,
    required this.rowSpan,
    this.columnStart,
    this.rowStart,
  });

  final String id;
  final int columnSpan;
  final int rowSpan;

  /// 1-based schema coordinates. Null means the item is auto-packed.
  final int? columnStart;
  final int? rowStart;
}

class HomeMetroPlacement {
  const HomeMetroPlacement({
    required this.id,
    required this.column,
    required this.row,
    required this.columnSpan,
    required this.rowSpan,
  });

  final String id;
  final int column;
  final int row;
  final int columnSpan;
  final int rowSpan;
}

bool homeMetroHasExplicitPlacement(Iterable<HomeMetroItem> items) {
  final list = items.toList(growable: false);
  if (list.isEmpty) return false;
  return list.every(
    (item) => item.columnStart != null && item.rowStart != null,
  );
}

/// Places Home metro tiles.
///
/// When every tile declares columnStart/rowStart, those coordinates are used
/// so the mosaic matches the web 6-column contract. Otherwise items are packed
/// in schema order.
List<HomeMetroPlacement> placeHomeMetroGrid({
  required List<HomeMetroItem> items,
  required int columns,
  required bool clampColumnSpan,
}) {
  if (columns <= 0) return const <HomeMetroPlacement>[];
  if (homeMetroHasExplicitPlacement(items)) {
    return _placeExplicit(
      items,
      columns: columns,
      clampColumnSpan: clampColumnSpan,
    );
  }
  return _pack(
    items,
    columns: columns,
    clampColumnSpan: clampColumnSpan,
  );
}

List<HomeMetroPlacement> _placeExplicit(
  List<HomeMetroItem> items, {
  required int columns,
  required bool clampColumnSpan,
}) {
  final occupied = <List<bool>>[];
  final result = <HomeMetroPlacement>[];

  void ensureRows(int count) {
    while (occupied.length < count) {
      occupied.add(List<bool>.filled(columns, false));
    }
  }

  bool fits(int row, int col, int rowSpan, int colSpan) {
    if (col + colSpan > columns) return false;
    ensureRows(row + rowSpan);
    for (var r = row; r < row + rowSpan; r++) {
      for (var c = col; c < col + colSpan; c++) {
        if (occupied[r][c]) return false;
      }
    }
    return true;
  }

  void occupy(int row, int col, int rowSpan, int colSpan) {
    ensureRows(row + rowSpan);
    for (var r = row; r < row + rowSpan; r++) {
      for (var c = col; c < col + colSpan; c++) {
        occupied[r][c] = true;
      }
    }
  }

  for (final item in items) {
    final requestedSpan = clampColumnSpan
        ? item.columnSpan.clamp(1, columns).toInt()
        : mathMax(1, item.columnSpan);
    final rowSpan = mathMax(1, item.rowSpan);
    var column = (item.columnStart ?? 1) - 1;
    if (column < 0) column = 0;
    var row = mathMax(0, (item.rowStart ?? 1) - 1);

    var span = requestedSpan;
    if (column + span > columns) {
      span = mathMax(1, columns - column);
    }

    // If requested coordinates fit without collision, place directly:
    if (column < columns && fits(row, column, rowSpan, span)) {
      occupy(row, column, rowSpan, span);
      result.add(
        HomeMetroPlacement(
          id: item.id,
          column: column,
          row: row,
          columnSpan: span,
          rowSpan: rowSpan,
        ),
      );
      continue;
    }

    // Coordinate collision or out-of-bounds column: find the next available non-overlapping slot
    var placed = false;
    for (var r = row; !placed; r++) {
      for (var c = 0; c < columns; c++) {
        final currentSpan = clampColumnSpan
            ? item.columnSpan.clamp(1, columns - c).toInt()
            : mathMax(1, item.columnSpan);
        if (fits(r, c, rowSpan, currentSpan)) {
          occupy(r, c, rowSpan, currentSpan);
          result.add(
            HomeMetroPlacement(
              id: item.id,
              column: c,
              row: r,
              columnSpan: currentSpan,
              rowSpan: rowSpan,
            ),
          );
          placed = true;
          break;
        }
      }
    }
  }
  return result;
}

List<HomeMetroPlacement> _pack(
  List<HomeMetroItem> items, {
  required int columns,
  required bool clampColumnSpan,
}) {
  final occupied = <List<bool>>[];
  final result = <HomeMetroPlacement>[];

  void ensureRows(int count) {
    while (occupied.length < count) {
      occupied.add(List<bool>.filled(columns, false));
    }
  }

  bool fits(int row, int col, int rowSpan, int colSpan) {
    if (col + colSpan > columns) return false;
    ensureRows(row + rowSpan);
    for (var r = row; r < row + rowSpan; r++) {
      for (var c = col; c < col + colSpan; c++) {
        if (occupied[r][c]) return false;
      }
    }
    return true;
  }

  void occupy(int row, int col, int rowSpan, int colSpan) {
    ensureRows(row + rowSpan);
    for (var r = row; r < row + rowSpan; r++) {
      for (var c = col; c < col + colSpan; c++) {
        occupied[r][c] = true;
      }
    }
  }

  for (final item in items) {
    final colSpan = (clampColumnSpan
            ? item.columnSpan.clamp(1, columns)
            : mathMax(1, item.columnSpan))
        .toInt();
    final rowSpan = mathMax(1, item.rowSpan);

    if (colSpan > columns) {
      final row = occupied.length;
      occupy(row, 0, rowSpan, columns);
      result.add(
        HomeMetroPlacement(
          id: item.id,
          column: 0,
          row: row,
          columnSpan: columns,
          rowSpan: rowSpan,
        ),
      );
      continue;
    }

    var placed = false;
    for (var row = 0; !placed; row++) {
      for (var col = 0; col < columns; col++) {
        if (fits(row, col, rowSpan, colSpan)) {
          occupy(row, col, rowSpan, colSpan);
          result.add(
            HomeMetroPlacement(
              id: item.id,
              column: col,
              row: row,
              columnSpan: colSpan,
              rowSpan: rowSpan,
            ),
          );
          placed = true;
          break;
        }
      }
    }
  }

  return result;
}

int mathMax(int a, int b) => a > b ? a : b;
