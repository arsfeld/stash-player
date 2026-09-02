import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/browse_context.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';

const _filter = SceneFilter(sort: SceneSort.date);

void main() {
  test('the first scene cannot go back', () {
    const context = BrowseContext(filter: _filter, index: 0, total: 5);

    expect(context.canGoPrevious, isFalse);
    expect(context.canGoNext, isTrue);
  });

  test('the last scene cannot go forward', () {
    const context = BrowseContext(filter: _filter, index: 4, total: 5);

    expect(context.canGoPrevious, isTrue);
    expect(context.canGoNext, isFalse);
  });

  test('a single-scene ordering can go neither way', () {
    const context = BrowseContext(filter: _filter, index: 0, total: 1);

    expect(context.canGoPrevious, isFalse);
    expect(context.canGoNext, isFalse);
  });

  test('at() moves the index and keeps the filter and total', () {
    const context = BrowseContext(filter: _filter, index: 2, total: 5);

    final moved = context.at(3);

    expect(moved.index, 3);
    expect(moved.filter, _filter);
    expect(moved.total, 5);
  });

  test('two contexts with the same fields are equal', () {
    // SceneDestination compares equal by value, and the router rebuilds
    // its page list on every AppController state change. Without this,
    // re-emitting the same destination would look like a new one.
    const a = BrowseContext(filter: _filter, index: 2, total: 5);
    const b = BrowseContext(filter: _filter, index: 2, total: 5);

    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
