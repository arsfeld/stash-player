import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import 'connection_controller.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({
    required this.onConnected,
    required this.initialConfig,
    required this.settingsMode,
    this.onCancel,
    super.key,
  });

  final VoidCallback onConnected;
  final ConnectionConfig initialConfig;
  final bool settingsMode;
  final VoidCallback? onCancel;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final FocusNode _urlFocusNode;
  late final FocusNode _apiKeyFocusNode;
  var _showApiKey = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: widget.initialConfig.serverUrl,
    );
    _apiKeyController = TextEditingController(
      text: widget.initialConfig.apiKey,
    );
    _urlFocusNode = FocusNode();
    _apiKeyFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
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
      },
    );
    final controller = ref.read(connectionControllerProvider);
    final state = ref.watch(
      connectionControllerProvider.select((value) => value.state),
    );
    final loading = state.phase == ConnectionPhase.loading;

    return Scaffold(
      appBar: widget.settingsMode
          ? AppBar(title: const Text('Connection settings'))
          : null,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
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
                  onSubmitted: (_) => _apiKeyFocusNode.requestFocus(),
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
                      message: _showApiKey ? 'Hide API key' : 'Show API key',
                      child: IconButton(
                        onPressed: () =>
                            setState(() => _showApiKey = !_showApiKey),
                        icon: Icon(
                          _showApiKey ? Icons.visibility_off : Icons.visibility,
                        ),
                      ),
                    ),
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
                if (state.serverVersion case final String version) ...[
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
    );
  }
}
