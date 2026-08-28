import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Opens a [Uri] in the system's default handler (typically the user's
/// web browser). The only place besides its own production implementation
/// allowed to depend on `package:url_launcher` — every caller talks to
/// this narrow interface instead, so a test can assert *which* [Uri]
/// "Open in Stash" would have opened without touching a real browser or
/// OS shell.
///
/// Every caller must resolve the [Uri] passed here via
/// [resolveStashSceneUrl] (or something equally careful about never
/// carrying an `apikey`) — never an authenticated media URL. GTK's own
/// `Client::authenticated_url` equivalent (`lib/services/authenticated_url.dart`)
/// is for the video/thumbnail pipeline only; "Open in Stash" always opens
/// the plain, unauthenticated web UI URL, which the browser's own
/// (cookie- or already-logged-in) session handles.
abstract interface class ExternalUrlLauncher {
  Future<bool> open(Uri uri);
}

/// Production [ExternalUrlLauncher]: forwards to `url_launcher`'s
/// top-level `launchUrl`, preferring the external browser/application
/// over an in-app webview.
class UrlLauncherExternalUrlLauncher implements ExternalUrlLauncher {
  const UrlLauncherExternalUrlLauncher();

  @override
  Future<bool> open(Uri uri) => url_launcher.launchUrl(
    uri,
    mode: url_launcher.LaunchMode.externalApplication,
  );
}

/// Resolves the "Open in Stash" URL for [sceneId] against [baseUrl] — the
/// configured server's own root, exactly as `ConnectionConfig.serverUrl`
/// stores it. **Never** pass an authenticated stream URL here.
///
/// Deliberately rebuilds the [Uri] from just [baseUrl]'s
/// scheme/userInfo/host/port and a freshly-built path — [baseUrl]'s own
/// query string (and fragment) are never carried forward, so an API key
/// that ever ended up embedded in a misconfigured server URL can't leak
/// into the browser's address bar either (see the "never includes
/// apikey" hazard in Task 11's brief). [sceneId] is percent-encoded via
/// [Uri]'s own `pathSegments` constructor parameter — never string
/// concatenation with `Uri.encodeComponent`, which would double-encode an
/// id that already contains a percent-escaped character.
Uri resolveStashSceneUrl(String baseUrl, String sceneId) {
  final base = Uri.parse(baseUrl);
  final segments = [
    ...base.pathSegments.where((segment) => segment.isNotEmpty),
    'scenes',
    sceneId,
  ];
  return Uri(
    scheme: base.scheme.isEmpty ? 'https' : base.scheme,
    userInfo: base.userInfo.isEmpty ? null : base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: segments,
  );
}

/// Provider for the production [ExternalUrlLauncher]. Tests override this
/// with a recording fake rather than launching a real browser.
final externalUrlLauncherProvider = Provider<ExternalUrlLauncher>(
  (ref) => const UrlLauncherExternalUrlLauncher(),
);
