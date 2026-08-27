import 'dart:async';

import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/services/connection_store.dart';
import 'package:stash_player_flutter/services/stash_api.dart';

class FakeConnectionStore implements ConnectionStore {
  FakeConnectionStore({this.saved = const ConnectionConfig(), this.loadFuture});

  ConnectionConfig saved;

  /// When set, `load()` returns this instead of resolving `saved`
  /// immediately — lets tests hold a `load()` call pending (e.g. via a
  /// `Completer`) to exercise late-resolution behavior.
  final Future<ConnectionConfig>? loadFuture;

  final List<ConnectionConfig> saveCalls = <ConnectionConfig>[];

  @override
  Future<ConnectionConfig> load(Map<String, String> environment) =>
      loadFuture ?? Future.value(saved);

  @override
  Future<void> save(ConnectionConfig config) async {
    saveCalls.add(config);
    saved = config;
  }
}

/// One recorded `findScenes` call, with its own [completer] so a test can
/// resolve or reject calls individually and out of order — e.g. to
/// exercise a stale-response race between two in-flight requests.
class FindScenesCall {
  FindScenesCall({
    required this.filter,
    required this.page,
    required this.perPage,
  });

  final SceneFilter filter;
  final int page;
  final int perPage;
  final Completer<ScenePage> completer = Completer<ScenePage>();
}

class FakeStashApi implements StashApi {
  FakeStashApi({this.versionValue, this.versionFailure, this.versionFuture});

  final String? versionValue;
  final Failure? versionFailure;
  final Future<String>? versionFuture;

  /// `findScenes` results consumed in call order: as long as this (or
  /// [pageFailures]) has an entry, each call completes immediately with
  /// the next one. Leave both empty and resolve/reject a specific
  /// [FindScenesCall.completer] from [calls] directly for full control
  /// over completion order and timing.
  final List<ScenePage> pages = [];

  /// `findScenes` failures consumed in call order, consulted ahead of
  /// [pages].
  final List<Failure> pageFailures = [];

  /// Every `findScenes` call, in the order received.
  final List<FindScenesCall> calls = [];

  List<int> get requestedPages => calls.map((call) => call.page).toList();

  List<int> get requestedPerPage => calls.map((call) => call.perPage).toList();

  List<SceneFilter> get requestedFilters =>
      calls.map((call) => call.filter).toList();

  @override
  Future<String> version() async {
    if (versionFailure case final Failure failure) throw failure;
    if (versionFuture case final Future<String> future) return future;
    return versionValue!;
  }

  @override
  Future<Scene?> findScene(String id) => throw UnimplementedError();

  @override
  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  }) {
    final call = FindScenesCall(filter: filter, page: page, perPage: perPage);
    calls.add(call);
    if (pageFailures.isNotEmpty) {
      call.completer.completeError(pageFailures.removeAt(0));
    } else if (pages.isNotEmpty) {
      call.completer.complete(pages.removeAt(0));
    }
    return call.completer.future;
  }

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) => throw UnimplementedError();
}
