import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:stash_player_flutter/domain/failure.dart';
import 'package:stash_player_flutter/domain/scene.dart';
import 'package:stash_player_flutter/domain/scene_filter.dart';
import 'package:stash_player_flutter/services/http_stash_api.dart';

void main() {
  test('findScenes sends filters, ApiKey, and decodes typed scenes', () async {
    final transport = RecordingClient(fixture('find_scenes_default.json'));
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: 'SECRET',
      client: transport,
    );

    final page = await api.findScenes(
      const SceneFilter(
        query: 'alpha',
        sort: SceneSort.rating,
        direction: SortDirection.ascending,
        minimumRating: 60,
        organized: true,
        hideTracked: true,
      ),
      page: 2,
      perPage: 48,
    );

    expect(transport.lastRequest.headers['ApiKey'], 'SECRET');
    // Deliberately *not* `expect(transport.lastQuery, findScenesDocument)`
    // — that would be tautological, since both sides read the exact same
    // mutable production constant and would still match each other even
    // if a field were dropped from it. These instead pin literal
    // substrings of the actual wire bytes, independent of that constant,
    // so a selection set that silently lost `rating100` or `paths {
    // stream }` — completely invisible to the hand-written fixtures,
    // which would still supply the field regardless of what was actually
    // requested — now fails here (final review §3b).
    expect(transport.lastQuery, contains('rating100'));
    expect(transport.lastQuery, contains('stream'));
    expect(transport.lastVariables['filter'], containsPair('sort', 'rating'));
    expect(transport.lastVariables['filter'], containsPair('direction', 'ASC'));
    // A page<->perPage swap (`http_stash_api.dart:167-168`) would pass
    // every other assertion in this file unnoticed (final review §3b) —
    // pin both independently, against the distinct values supplied above.
    expect(transport.lastVariables['filter'], containsPair('page', 2));
    expect(transport.lastVariables['filter'], containsPair('per_page', 48));
    expect(transport.lastVariables['filter'], containsPair('q', 'alpha'));
    expect(
      transport.lastVariables['scene_filter'],
      containsPair('rating100', {'value': 59, 'modifier': 'GREATER_THAN'}),
    );
    expect(
      transport.lastVariables['scene_filter'],
      containsPair('organized', true),
    );
    expect(
      transport.lastVariables['scene_filter'],
      containsPair('o_counter', {'value': 0, 'modifier': 'EQUALS'}),
    );
    expect(page.scenes.singleWhere((scene) => scene.id == '1001').id, '1001');
  });

  test('omits ApiKey header when key is empty', () async {
    final transport = RecordingClient(fixture('find_scenes_default.json'));
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: transport,
    );

    await api.findScenes(const SceneFilter(), page: 1, perPage: 24);

    expect(transport.lastRequest.headers.containsKey('ApiKey'), isFalse);
  });

  test('version returns a validated version string', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient(fixture('version.json')),
    );

    expect(await api.version(), 'v0.31.0');
  });

  test('version rejects a missing version value', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient('{"data":{"version":{}}}'),
    );

    expect(api.version(), throwsA(isA<FormatFailure>()));
  });

  test('uses random seed only for random sort', () async {
    final transport = RecordingClient(fixture('find_scenes_default.json'));
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: transport,
    );

    await api.findScenes(
      const SceneFilter(sort: SceneSort.random, randomSeed: 42),
      page: 1,
      perPage: 24,
    );

    expect(
      (transport.lastVariables['filter'] as Map<String, Object?>)['sort'],
      'random_42',
    );
  });

  test('maps every sort to its Stash wire value', () async {
    const cases = <(SceneSort, String)>[
      (SceneSort.date, 'date'),
      (SceneSort.title, 'title'),
      (SceneSort.rating, 'rating'),
      (SceneSort.playCount, 'play_count'),
      (SceneSort.duration, 'duration'),
      (SceneSort.createdAt, 'created_at'),
      (SceneSort.updatedAt, 'updated_at'),
      (SceneSort.random, 'random_42'),
    ];
    for (final entry in cases) {
      final transport = RecordingClient(fixture('find_scenes_default.json'));
      final api = HttpStashApi(
        baseUri: Uri.parse('https://stash.test'),
        apiKey: '',
        client: transport,
      );

      await api.findScenes(
        SceneFilter(sort: entry.$1, randomSeed: 42),
        page: 1,
        perPage: 24,
      );

      expect(
        (transport.lastVariables['filter'] as Map<String, Object?>)['sort'],
        entry.$2,
      );
    }
  });

  test('defaults optional scene fields when Stash omits them', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient(fixture('find_scenes_partial.json')),
    );

    final scene = (await api.findScenes(
      const SceneFilter(),
      page: 1,
      perPage: 24,
    )).scenes.single;

    expect(scene.details, isNull);
    expect(scene.resumeTime, isNull);
    expect(scene.playCount, isNull);
    expect(scene.files.single.path, isNull);
  });

  test('rejects a scene missing its required id', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient(
        '{"data":{"findScenes":{"count":1,"scenes":[{"paths":{}}]}}}',
      ),
    );

    expect(
      api.findScenes(const SceneFilter(), page: 1, perPage: 24),
      throwsA(isA<FormatFailure>()),
    );
  });

  test('rejects malformed GraphQL data', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient('{"data":[]}'),
    );

    expect(api.version(), throwsA(isA<FormatFailure>()));
  });

  test('returns GraphQL errors without leaking credentials', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: 'SECRET',
      client: RecordingClient(
        '{"errors":[{"message":"SECRET apikey=SECRET"}],"data":null}',
      ),
    );

    expect(
      api.version(),
      throwsA(
        isA<GraphQlFailure>().having(
          (failure) => failure.message,
          'message',
          '*** apikey=***',
        ),
      ),
    );
  });

  test('rejects HTTP status failures before decoding', () async {
    final unauthorized = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: 'SECRET',
      client: RecordingClient('SECRET', statusCode: 401),
    );
    final serverError = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient('failure', statusCode: 500),
    );

    await expectLater(
      unauthorized.version(),
      throwsA(
        isA<HttpFailure>().having(
          (failure) => failure.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
    await expectLater(
      serverError.version(),
      throwsA(
        isA<HttpFailure>().having(
          (failure) => failure.statusCode,
          'statusCode',
          500,
        ),
      ),
    );
  });

  test('findScene returns null for a missing scene', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient('{"data":{"findScene":null}}'),
    );

    expect(await api.findScene('missing'), isNull);
  });

  test('findScene decodes a typed scene', () async {
    final transport = RecordingClient(fixture('find_scene.json'));
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: transport,
    );

    final scene = await api.findScene('1001');

    // See the `findScenes` test's own comment on why this isn't a
    // comparison against the `findSceneDocument` constant itself.
    expect(transport.lastQuery, contains('rating100'));
    expect(transport.lastQuery, contains('stream'));
    expect(scene?.id, '1001');
    expect(scene?.studio?.name, 'Studio Foo');
  });

  test('saveSceneActivity sends Stash variable names', () async {
    final transport = RecordingClient('{"data":{"sceneSaveActivity":true}}');
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: transport,
    );

    await api.saveSceneActivity(
      id: '1001',
      resumeTime: 9.5,
      playDuration: 4.25,
    );

    // Same rationale as the `findScenes`/`findScene` tests above.
    expect(transport.lastQuery, contains('resume_time'));
    expect(transport.lastQuery, contains('playDuration'));
    expect(transport.lastVariables, {
      'id': '1001',
      'resume_time': 9.5,
      'playDuration': 4.25,
    });
  });

  test('scene display title and effective resume use safe fallbacks', () {
    const paths = ScenePaths();
    final scene = Scene(
      id: '1001',
      paths: paths,
      files: [SceneFile(path: r'C:\\library\\fallback.mkv', duration: 600)],
      resumeTime: 595,
    );
    final unknownDuration = Scene(id: '1002', paths: paths, resumeTime: 15);

    expect(scene.displayTitle, 'fallback');
    expect(scene.effectiveResume, isNull);
    expect(unknownDuration.effectiveResume, 15);
  });

  test('decoded scene collections cannot be mutated', () async {
    final api = HttpStashApi(
      baseUri: Uri.parse('https://stash.test'),
      apiKey: '',
      client: RecordingClient(fixture('find_scenes_default.json')),
    );

    final page = await api.findScenes(
      const SceneFilter(),
      page: 1,
      perPage: 24,
    );
    final scene = page.scenes.single;

    expect(() => page.scenes[0] = scene, throwsUnsupportedError);
    expect(() => scene.files[0] = scene.files.single, throwsUnsupportedError);
    expect(
      () => scene.performers[0] = scene.performers.single,
      throwsUnsupportedError,
    );
  });
}

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

class RecordingClient extends http.BaseClient {
  RecordingClient(this.responseBody, {this.statusCode = 200});

  final String responseBody;
  final int statusCode;
  late http.BaseRequest lastRequest;
  late Map<String, Object?> lastVariables;

  /// The `query` string of the last GraphQL request sent — a dropped
  /// field (e.g. `paths { stream }` or `rating100`) from a selection set
  /// is otherwise completely invisible to this test file, since the
  /// hand-written fixtures would still supply the field regardless of
  /// what was actually requested (final review §3b).
  late String lastQuery;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    final decoded = jsonDecode(await request.finalize().bytesToString());
    final envelope = Map<String, Object?>.from(decoded as Map);
    lastQuery = envelope['query'] as String;
    lastVariables = Map<String, Object?>.from(envelope['variables'] as Map);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
      statusCode,
      headers: const {'content-type': 'application/json'},
    );
  }
}
