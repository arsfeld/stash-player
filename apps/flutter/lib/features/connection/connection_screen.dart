import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/connection.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_spinner.dart';
import 'connection_controller.dart';
import 'connection_form.dart';

/// The first-launch page, shown full-screen while no connection is saved.
/// Changing an existing connection happens in `ConnectionSettingsDialog`,
/// over the library, instead.
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({
    required this.onConnected,
    this.initialConfig,
    super.key,
  });

  final VoidCallback onConnected;

  /// Seeds the form fields directly, bypassing the controller's `load()`.
  ///
  /// Pass `null` (the normal case) to have the form call `load()` on mount
  /// and fill the fields from the effective config once it resolves. Pass
  /// an explicit config only to pin the seed; the form then never fetches.
  final ConnectionConfig? initialConfig;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final _fields = ConnectionFields(
    widget.initialConfig ?? const ConnectionConfig(),
  );

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectionPhase>(
      connectionControllerProvider.select((value) => value.state.phase),
      (previous, next) {
        if (previous != ConnectionPhase.ready &&
            next == ConnectionPhase.ready) {
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
      body: LayoutBuilder(
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
                      const SizedBox(height: AppTokens.space5),
                      ConnectionForm(
                        fields: _fields,
                        loadOnMount: widget.initialConfig == null,
                      ),
                      if (state.serverVersion case final String version) ...[
                        const SizedBox(height: AppTokens.space4),
                        Text('Connected to Stash $version.'),
                      ],
                      const SizedBox(height: AppTokens.space5),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: ListenableBuilder(
                          listenable: _fields.serverUrl,
                          builder: (context, _) => Tooltip(
                            message:
                                'Test this connection and save it if Stash '
                                'responds.',
                            child: FilledButton(
                              onPressed: loading || !_fields.canSubmit
                                  ? null
                                  : () =>
                                        controller.testAndSave(_fields.current),
                              child: loading
                                  ? const AppSpinner(size: 18)
                                  : const Text('Connect'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
