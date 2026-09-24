import 'package:stash_player_flutter/ui/toolbar/app_toolbar.dart';
import 'package:stash_player_flutter/ui/toolbar/native_toolbar.dart';

/// A [NativeToolbar] that records every spec it is handed. With
/// [available] false it reports the native side missing, as the channel
/// does.
class RecordingToolbar implements NativeToolbar {
  RecordingToolbar({this.available = true});

  bool available;
  final List<AppToolbar> sent = [];

  AppToolbar get last => sent.last;

  /// The item with [id] in the last spec, searching inside groups.
  T item<T extends AppToolbarItem>(String id) {
    Iterable<AppToolbarItem> flatten(List<AppToolbarItem> items) sync* {
      for (final item in items) {
        yield item;
        if (item is AppToolbarGroup) yield* flatten(item.children);
      }
    }

    return flatten(last.items).firstWhere((item) => item.id == id) as T;
  }

  @override
  Future<bool> set(AppToolbar toolbar) async {
    sent.add(toolbar);
    return available;
  }
}
