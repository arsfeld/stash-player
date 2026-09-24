import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../ui/widgets/app_dialog.dart';
import 'connection_controller.dart';
import 'connection_form.dart';

/// Changing the active connection, as a dialog over the library.
///
/// Save runs the same test-and-save as the first-launch page. On success
/// it hands the config to [AppController.replaceConnection], whose switch
/// back to `library()` takes this dialog's page off the stack. On failure
/// the dialog stays open with the error under the relevant field.
///
/// Cancel, Escape and the barrier are disabled while a test runs:
/// `testAndSave` stores the config the moment Stash answers, so closing
/// mid-test would leave a new connection saved but not in use until the
/// next launch. `HttpStashApi`'s request timeout bounds the wait.
class ConnectionSettingsDialog extends ConsumerStatefulWidget {
  const ConnectionSettingsDialog({super.key});

  @override
  ConsumerState<ConnectionSettingsDialog> createState() =>
      _ConnectionSettingsDialogState();
}

class _ConnectionSettingsDialogState
    extends ConsumerState<ConnectionSettingsDialog> {
  final _fields = ConnectionFields();

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
          final config = ref.read(connectionControllerProvider).state.config;
          unawaited(
            ref.read(appControllerProvider.notifier).replaceConnection(config),
          );
        }
      },
    );
    final controller = ref.read(connectionControllerProvider);
    final loading = ref.watch(
      connectionControllerProvider.select(
        (value) => value.state.phase == ConnectionPhase.loading,
      ),
    );

    return ListenableBuilder(
      listenable: _fields.serverUrl,
      builder: (context, _) => AppDialog(
        title: 'Connection',
        cancel: AppDialogAction(
          label: 'Cancel',
          onPressed: loading
              ? null
              : ref.read(appControllerProvider.notifier).closeSettings,
        ),
        confirm: AppDialogAction(
          label: 'Save',
          busy: loading,
          onPressed: _fields.canSubmit
              ? () => controller.testAndSave(_fields.current)
              : null,
        ),
        child: ConnectionForm(fields: _fields, loadOnMount: true),
      ),
    );
  }
}
