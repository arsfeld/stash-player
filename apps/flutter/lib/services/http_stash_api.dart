import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/failure.dart';
import '../domain/scene.dart';
import '../domain/scene_filter.dart';
import 'authenticated_url.dart';
import 'stash_api.dart';

/// Deadline for a single GraphQL POST. `package:http`'s `IOClient` sets no
/// request deadline of its own — a server that accepts the TCP connection
/// and then never responds (a firewall drop, a misrouted VPN, the right
/// host on the wrong port) would otherwise hang the awaiting call forever.
/// 15s is generous enough for a slow-but-working Stash instance (a cold
/// `findScenes` against a large library over a slow link) while still
/// bounding first-launch "Test connection", the library spinner, and
/// activity checkpoints to a duration a user will actually wait out rather
/// than kill the app. `TimeoutException` falls through `_post`'s existing
/// catch-all into a `TransportFailure`, same as any other transport error.
const _requestTimeout = Duration(seconds: 15);

const String findScenesDocument = r'''
query FindScenes($filter: FindFilterType, $scene_filter: SceneFilterType) {
  findScenes(filter: $filter, scene_filter: $scene_filter) {
    count
    scenes {
      id title details date rating100 resume_time play_count play_duration o_counter
      paths { screenshot preview sprite stream webp }
      files { path duration width height video_codec frame_rate }
      studio { id name }
      performers { id name }
    }
  }
}
''';

const String findSceneDocument = r'''
query FindScene($id: ID!) {
  findScene(id: $id) {
    id title details date rating100 resume_time play_count play_duration o_counter
    paths { screenshot preview sprite stream webp }
    files { path duration width height video_codec frame_rate }
    studio { id name }
    performers { id name }
  }
}
''';

const String sceneSaveActivityDocument = r'''
mutation SceneSaveActivity($id: ID!, $resume_time: Float, $playDuration: Float) {
  sceneSaveActivity(id: $id, resume_time: $resume_time, playDuration: $playDuration)
}
''';

const String sceneIncrementODocument = r'''
mutation SceneIncrementO($id: ID!) {
  sceneIncrementO(id: $id)
}
''';

const String sceneResetODocument = r'''
mutation SceneResetO($id: ID!) {
  sceneResetO(id: $id)
}
''';

const String _versionDocument = 'query Version { version { version } }';

class HttpStashApi implements StashApi {
  HttpStashApi({
    required this.baseUri,
    required this.apiKey,
    required this.client,
  });

  final Uri baseUri;
  final String apiKey;
  final http.Client client;

  @override
  Future<String> version() => _post(_versionDocument, const {}, (data) {
    final version = _requiredMap(data, 'version');
    return _requiredString(version, 'version');
  });

  @override
  Future<ScenePage> findScenes(
    SceneFilter filter, {
    required int page,
    required int perPage,
  }) => _post(findScenesDocument, _findScenesVariables(filter, page, perPage), (
    data,
  ) {
    final pageData = _requiredMap(data, 'findScenes');
    final scenes = _requiredList(pageData, 'scenes')
        .map((scene) => _decodeScene(_asMap(scene, 'findScenes.scenes[]')))
        .toList(growable: false);
    return ScenePage(total: _requiredInt(pageData, 'count'), scenes: scenes);
  });

  @override
  Future<Scene?> findScene(String id) =>
      _post(findSceneDocument, {'id': id}, (data) {
        final rawScene = data['findScene'];
        return rawScene == null
            ? null
            : _decodeScene(_asMap(rawScene, 'findScene'));
      });

  @override
  Future<void> saveSceneActivity({
    required String id,
    required double resumeTime,
    required double playDuration,
  }) async {
    final saved = await _post(sceneSaveActivityDocument, {
      'id': id,
      'resume_time': resumeTime,
      'playDuration': playDuration,
    }, (data) => data['sceneSaveActivity']);
    if (saved is! bool || !saved) {
      throw const FormatFailure('Stash did not save scene activity.');
    }
  }

  @override
  Future<int> incrementO(String id) =>
      _mutateO(sceneIncrementODocument, 'sceneIncrementO', id);

  @override
  Future<int> resetO(String id) =>
      _mutateO(sceneResetODocument, 'sceneResetO', id);

  /// Both O-counter mutations have the same shape: one `ID!`, one
  /// integer back. Shared so the two can never disagree about how a
  /// malformed response is reported.
  Future<int> _mutateO(String document, String field, String id) =>
      _post(document, {'id': id}, (data) {
        final count = data[field];
        if (count is! int) {
          throw const FormatFailure('Stash returned no O-counter value.');
        }
        return count;
      });

  Future<T> _post<T>(
    String document,
    Map<String, Object?> variables,
    T Function(Map<String, Object?> data) decode,
  ) async {
    try {
      final response = await client
          .post(
            baseUri.resolve('graphql'),
            headers: {
              'content-type': 'application/json',
              if (apiKey.isNotEmpty) 'ApiKey': apiKey,
            },
            body: jsonEncode({'query': document, 'variables': variables}),
          )
          .timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpFailure(
          response.statusCode,
          redactSensitive(response.body, apiKey: apiKey),
        );
      }

      final envelope = _asMap(jsonDecode(response.body), 'response');
      final errors = envelope['errors'];
      if (errors != null) {
        final messages = _asList(errors, 'errors')
            .map(
              (error) => _requiredString(_asMap(error, 'errors[]'), 'message'),
            )
            .join('; ');
        if (messages.isNotEmpty) {
          throw GraphQlFailure(redactSensitive(messages, apiKey: apiKey));
        }
      }
      return decode(_asMap(envelope['data'], 'data'));
    } on Failure {
      rethrow;
    } on http.ClientException catch (error) {
      throw TransportFailure(redactSensitive(error.message, apiKey: apiKey));
    } on FormatException catch (error) {
      throw FormatFailure(redactSensitive(error.message, apiKey: apiKey));
    } catch (error) {
      throw TransportFailure(redactSensitive(error.toString(), apiKey: apiKey));
    }
  }
}

Map<String, Object?> _findScenesVariables(
  SceneFilter filter,
  int page,
  int perPage,
) {
  final sort = filter.sort == SceneSort.random && filter.randomSeed != null
      ? 'random_${filter.randomSeed}'
      : switch (filter.sort) {
          SceneSort.date => 'date',
          SceneSort.title => 'title',
          SceneSort.rating => 'rating',
          SceneSort.playCount => 'play_count',
          SceneSort.duration => 'duration',
          SceneSort.createdAt => 'created_at',
          SceneSort.updatedAt => 'updated_at',
          SceneSort.random => 'random',
        };
  final findFilter = <String, Object?>{
    'page': page,
    'per_page': perPage,
    'sort': sort,
    'direction': filter.direction == SortDirection.ascending ? 'ASC' : 'DESC',
  };
  if (filter.query.isNotEmpty) findFilter['q'] = filter.query;

  final sceneFilter = <String, Object?>{};
  if (filter.minimumRating case final int minimumRating) {
    sceneFilter['rating100'] = {
      'value': minimumRating > 0 ? minimumRating - 1 : 0,
      'modifier': 'GREATER_THAN',
    };
  }
  if (filter.organized case final bool organized) {
    sceneFilter['organized'] = organized;
  }
  if (filter.hideTracked) {
    sceneFilter['o_counter'] = {'value': 0, 'modifier': 'EQUALS'};
  }
  return {'filter': findFilter, 'scene_filter': sceneFilter};
}

Scene _decodeScene(Map<String, Object?> source) => Scene(
  id: _requiredString(source, 'id'),
  paths: _decodePaths(_requiredMap(source, 'paths')),
  title: _optionalString(source, 'title'),
  details: _optionalString(source, 'details'),
  date: _optionalString(source, 'date'),
  rating100: _optionalInt(source, 'rating100'),
  resumeTime: _optionalDouble(source, 'resume_time'),
  playCount: _optionalInt(source, 'play_count'),
  playDuration: _optionalDouble(source, 'play_duration'),
  oCounter: _optionalInt(source, 'o_counter'),
  files:
      (source['files'] == null
              ? const <Object?>[]
              : _asList(source['files'], 'files'))
          .map((file) => _decodeFile(_asMap(file, 'files[]')))
          .toList(growable: false),
  studio: source['studio'] == null
      ? null
      : _decodeStudio(_asMap(source['studio'], 'studio')),
  performers:
      (source['performers'] == null
              ? const <Object?>[]
              : _asList(source['performers'], 'performers'))
          .map(
            (performer) => _decodePerformer(_asMap(performer, 'performers[]')),
          )
          .toList(growable: false),
);

ScenePaths _decodePaths(Map<String, Object?> source) => ScenePaths(
  screenshot: _optionalString(source, 'screenshot'),
  stream: _optionalString(source, 'stream'),
);

SceneFile _decodeFile(Map<String, Object?> source) => SceneFile(
  path: _optionalString(source, 'path'),
  duration: _optionalDouble(source, 'duration'),
  width: _optionalInt(source, 'width'),
  height: _optionalInt(source, 'height'),
  videoCodec: _optionalString(source, 'video_codec'),
  frameRate: _optionalDouble(source, 'frame_rate'),
);

StudioRef _decodeStudio(Map<String, Object?> source) => StudioRef(
  id: _requiredString(source, 'id'),
  name: _requiredString(source, 'name'),
);

PerformerRef _decodePerformer(Map<String, Object?> source) => PerformerRef(
  id: _requiredString(source, 'id'),
  name: _requiredString(source, 'name'),
);

Map<String, Object?> _asMap(Object? value, String path) {
  if (value is! Map) {
    throw FormatFailure('Expected an object at $path.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatFailure('Expected string keys at $path.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, Object?> _requiredMap(Map<String, Object?> source, String key) =>
    _asMap(source[key], key);

List<Object?> _asList(Object? value, String path) {
  if (value is! List) throw FormatFailure('Expected an array at $path.');
  return List<Object?>.from(value);
}

List<Object?> _requiredList(Map<String, Object?> source, String key) =>
    _asList(source[key], key);

String _requiredString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) {
    throw FormatFailure('Expected a non-empty string at $key.');
  }
  return value;
}

String? _optionalString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value == null) return null;
  if (value is! String) throw FormatFailure('Expected a string at $key.');
  return value;
}

int _requiredInt(Map<String, Object?> source, String key) =>
    _optionalInt(source, key) ??
    (throw FormatFailure('Expected an integer at $key.'));

int? _optionalInt(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value == null) return null;
  if (value is! num || value != value.roundToDouble()) {
    throw FormatFailure('Expected an integer at $key.');
  }
  return value.toInt();
}

double? _optionalDouble(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value == null) return null;
  if (value is! num) throw FormatFailure('Expected a number at $key.');
  return value.toDouble();
}
