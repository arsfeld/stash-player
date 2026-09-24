import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import '../../ui/icons/app_icons.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_form.dart';
import 'connection_controller.dart';

/// The connection form's text, owned by whichever screen hosts the form
/// (the first-launch page or the settings dialog) so that host can read
/// [current] and [canSubmit] for its own submit button.
class ConnectionFields {
  ConnectionFields([ConnectionConfig seed = const ConnectionConfig()])
    : _seed = seed,
      serverUrl = TextEditingController(text: seed.serverUrl),
      apiKey = TextEditingController(text: seed.apiKey),
      socksProxy = TextEditingController(text: seed.socksProxy);

  final TextEditingController serverUrl;
  final TextEditingController apiKey;
  final TextEditingController socksProxy;

  /// The config the fields were last filled from programmatically. A field
  /// whose text no longer matches it has been edited by the user, and
  /// [applyLoaded] leaves it alone.
  ConnectionConfig _seed;

  ConnectionConfig get current => ConnectionConfig(
    serverUrl: serverUrl.text,
    apiKey: apiKey.text,
    socksProxy: socksProxy.text,
  );

  /// Only a URL is required. Everything else is validated by
  /// `ConnectionController.testAndSave`, which reports under the field.
  bool get canSubmit => serverUrl.text.trim().isNotEmpty;

  /// Fills in [config], typically the stored connection once `load()`
  /// resolves, without overwriting anything typed since the last fill. The
  /// load runs in the background while the form is already usable, so it
  /// can land after the user has started typing.
  void applyLoaded(ConnectionConfig config) {
    if (serverUrl.text == _seed.serverUrl) serverUrl.text = config.serverUrl;
    if (apiKey.text == _seed.apiKey) apiKey.text = config.apiKey;
    if (socksProxy.text == _seed.socksProxy) {
      socksProxy.text = config.socksProxy;
    }
    _seed = config;
  }

  void dispose() {
    serverUrl.dispose();
    apiKey.dispose();
    socksProxy.dispose();
  }
}

/// The connection fields as two groups (Server, Network), with the
/// controller's validation and connection errors. It has no submit button:
/// the host supplies one, since the first-launch page and the settings
/// dialog place it differently.
class ConnectionForm extends ConsumerStatefulWidget {
  const ConnectionForm({
    required this.fields,
    required this.loadOnMount,
    super.key,
  });

  final ConnectionFields fields;

  /// Whether to read the stored connection on mount and fill [fields] from
  /// it. False only when the host has pinned its own seed.
  final bool loadOnMount;

  @override
  ConsumerState<ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends ConsumerState<ConnectionForm> {
  final _apiKeyFocusNode = FocusNode();
  final _serverUrlFocusNode = FocusNode();
  var _showApiKey = false;

  /// True from `initState` until the `load()` this form kicked off (when
  /// [ConnectionForm.loadOnMount]) resolves.
  ///
  /// The `ConnectionController` is shared across dialog opens rather than
  /// recreated per dialog instance, so on a reopen its state can still
  /// carry a previous attempt's fieldError/proxyFieldError/failure until
  /// this fresh load replaces it. While this is true the form ignores
  /// those fields rather than flash an error that was never true of the
  /// connection it's about to load.
  var _awaitingInitialLoad = false;

  @override
  void initState() {
    super.initState();
    if (widget.loadOnMount) {
      _awaitingInitialLoad = true;
      // Fire-and-forget: `load()` never touches provider state before its
      // first `await` (the controller's loading phase is reserved for
      // `testAndSave`, not this background fetch; see its doc comment),
      // so calling it here never trips Riverpod's "don't modify a provider
      // while the tree is building" guard.
      ref.read(connectionControllerProvider).load();
    }
  }

  @override
  void dispose() {
    _apiKeyFocusNode.dispose();
    _serverUrlFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loadOnMount) {
      ref.listen<ConnectionState>(
        connectionControllerProvider.select((value) => value.state),
        (previous, next) {
          widget.fields.applyLoaded(next.config);
          if (_awaitingInitialLoad) {
            setState(() => _awaitingInitialLoad = false);
          }
        },
      );
    }
    ref.listen<ConnectionPhase>(
      connectionControllerProvider.select((value) => value.state.phase),
      (previous, next) {
        // The fields disable (and so lose focus) for the duration of a
        // test; once it fails they re-enable, but nothing else gives
        // focus back, leaving the user with no cursor to correct the
        // entry with until they click into a field again.
        if (next == ConnectionPhase.failed) {
          _serverUrlFocusNode.requestFocus();
        }
      },
    );
    final state = ref.watch(
      connectionControllerProvider.select((value) => value.state),
    );
    final enabled = state.phase != ConnectionPhase.loading;
    final fieldError = _awaitingInitialLoad ? null : state.fieldError;
    final proxyFieldError = _awaitingInitialLoad ? null : state.proxyFieldError;
    final failureText = _awaitingInitialLoad ? null : state.failure;
    final fields = widget.fields;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppPreferencesGroup(
          title: 'Server',
          children: [
            AppEntryRow(
              fieldKey: const Key('connection-server-url'),
              label: 'Server URL',
              controller: fields.serverUrl,
              focusNode: _serverUrlFocusNode,
              enabled: enabled,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _apiKeyFocusNode.requestFocus(),
              errorText: fieldError,
            ),
            AppEntryRow(
              fieldKey: const Key('connection-api-key'),
              label: 'API key',
              hint: 'Optional',
              controller: fields.apiKey,
              focusNode: _apiKeyFocusNode,
              enabled: enabled,
              obscureText: !_showApiKey,
              textInputAction: TextInputAction.done,
              trailing: Tooltip(
                message: _showApiKey ? 'Hide API key' : 'Show API key',
                child: IconButton(
                  onPressed: () => setState(() => _showApiKey = !_showApiKey),
                  icon: AppIconView(_showApiKey ? AppIcon.eyeOff : AppIcon.eye),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space5),
        AppPreferencesGroup(
          title: 'Network',
          description:
              'Reach Stash through a SOCKS5 proxy, for a server only '
              'routable that way. Tailscale in userspace mode listens on '
              '127.0.0.1:1055.',
          children: [
            AppEntryRow(
              fieldKey: const Key('connection-socks-proxy'),
              label: 'SOCKS5 proxy',
              hint: 'Optional',
              controller: fields.socksProxy,
              enabled: enabled,
              textInputAction: TextInputAction.done,
              errorText: proxyFieldError,
            ),
          ],
        ),
        if (failureText case final String failure) ...[
          const SizedBox(height: AppTokens.space4),
          Text(
            failure,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}
