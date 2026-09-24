import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/filter_controls.dart';
import '../../ui/widgets/window_chrome.dart';
import 'connection_controller.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({
    required this.onConnected,
    required this.settingsMode,
    this.initialConfig,
    this.onCancel,
    super.key,
  });

  final VoidCallback onConnected;

  /// Seeds the form fields directly, bypassing the controller's `load()`.
  ///
  /// Pass `null` (the normal case for both first-launch and settings-mode
  /// mounts) to have the screen call `load()` on mount and populate the
  /// fields from the resulting effective config once it resolves. Pass an
  /// explicit config only when the caller wants to pin the seed itself —
  /// that value wins and the screen will not fetch or apply a loaded one.
  final ConnectionConfig? initialConfig;
  final bool settingsMode;
  final VoidCallback? onCancel;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _socksProxyController;
  late final FocusNode _urlFocusNode;
  late final FocusNode _apiKeyFocusNode;
  var _showApiKey = false;

  /// The config the fields were last populated from programmatically —
  /// either [ConnectionScreen.initialConfig] or a resolved `load()` result.
  /// Used to detect whether the user has since edited a field so a late
  /// `load()` resolution never clobbers text they already typed.
  late ConnectionConfig _seed;

  @override
  void initState() {
    super.initState();
    _seed = widget.initialConfig ?? const ConnectionConfig();
    _urlController = TextEditingController(text: _seed.serverUrl);
    _apiKeyController = TextEditingController(text: _seed.apiKey);
    _socksProxyController = TextEditingController(text: _seed.socksProxy);
    _urlFocusNode = FocusNode();
    _apiKeyFocusNode = FocusNode();
    if (widget.initialConfig == null) {
      // Fire-and-forget: `load()` never touches provider state before its
      // first `await` (the controller's loading phase is reserved for
      // `testAndSave`, not this background fetch — see its doc comment),
      // so calling it here never trips Riverpod's "don't modify a provider
      // while the tree is building" guard.
      ref.read(connectionControllerProvider).load();
    }
  }

  void _applyLoadedConfig(ConnectionConfig config) {
    if (_urlController.text == _seed.serverUrl) {
      _urlController.text = config.serverUrl;
    }
    if (_apiKeyController.text == _seed.apiKey) {
      _apiKeyController.text = config.apiKey;
    }
    if (_socksProxyController.text == _seed.socksProxy) {
      _socksProxyController.text = config.socksProxy;
    }
    _seed = config;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    _socksProxyController.dispose();
    _urlFocusNode.dispose();
    _apiKeyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectionState>(
      connectionControllerProvider.select((value) => value.state),
      (previous, next) {
        if (previous?.phase != ConnectionPhase.ready &&
            next.phase == ConnectionPhase.ready) {
          widget.onConnected();
        }
        if (widget.initialConfig == null) {
          _applyLoadedConfig(next.config);
        }
      },
    );
    final controller = ref.read(connectionControllerProvider);
    final state = ref.watch(
      connectionControllerProvider.select((value) => value.state),
    );
    final loading = state.phase == ConnectionPhase.loading;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.settingsMode)
            AppWindowChrome(
              children: [
                if (widget.onCancel case final VoidCallback onCancel)
                  AppIconAction(
                    icon: Icons.arrow_back,
                    tooltip: 'Back',
                    semanticLabel: 'Back to library',
                    onPressed: onCancel,
                  ),
                const SizedBox(width: AppTokens.space3),
                // Flexible, with its own overflow behaviour: the strip is
                // a bare Row and cannot decide that for its children (see
                // AppWindowChrome's doc). Unwrapped, this title takes its
                // full intrinsic width and overflows a 400px window at a
                // raised text scale, which on macOS has only
                // `width - 78 - 12` to render into.
                Flexible(
                  child: Text(
                    'Connection settings',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: const EdgeInsets.all(AppTokens.space5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Connect to Stash',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 24),
                            TextField(
                              key: const Key('connection-server-url'),
                              controller: _urlController,
                              focusNode: _urlFocusNode,
                              enabled: !loading,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) =>
                                  _apiKeyFocusNode.requestFocus(),
                              decoration: InputDecoration(
                                labelText: 'Stash server URL',
                                errorText: state.fieldError,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              key: const Key('connection-api-key'),
                              controller: _apiKeyController,
                              focusNode: _apiKeyFocusNode,
                              enabled: !loading,
                              obscureText: !_showApiKey,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: 'Stash API key (optional)',
                                suffixIcon: Tooltip(
                                  message: _showApiKey
                                      ? 'Hide API key'
                                      : 'Show API key',
                                  child: IconButton(
                                    onPressed: () => setState(
                                      () => _showApiKey = !_showApiKey,
                                    ),
                                    icon: Icon(
                                      _showApiKey
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              key: const Key('connection-socks-proxy'),
                              controller: _socksProxyController,
                              enabled: !loading,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: 'SOCKS5 proxy (optional)',
                                helperText:
                                    'Reach Stash through a SOCKS5 proxy, for a server '
                                    'only routable that way. Tailscale in userspace mode '
                                    'listens on 127.0.0.1:1055.',
                                helperMaxLines: 3,
                                errorText: state.proxyFieldError,
                              ),
                            ),
                            if (state.failure case final String failure) ...[
                              const SizedBox(height: 16),
                              Text(
                                failure,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                            if (state.serverVersion
                                case final String version) ...[
                              const SizedBox(height: 16),
                              Text('Connected to Stash $version.'),
                            ],
                            const SizedBox(height: 24),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                Tooltip(
                                  message:
                                      'Test this connection and save it if Stash responds.',
                                  child: FilledButton(
                                    onPressed: loading
                                        ? null
                                        : () => controller.testAndSave(
                                            ConnectionConfig(
                                              serverUrl: _urlController.text,
                                              apiKey: _apiKeyController.text,
                                              socksProxy:
                                                  _socksProxyController.text,
                                            ),
                                          ),
                                    child: loading
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Text('Test connection'),
                                  ),
                                ),
                                if (widget.settingsMode)
                                  OutlinedButton(
                                    onPressed: widget.onCancel,
                                    child: const Text('Cancel'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
