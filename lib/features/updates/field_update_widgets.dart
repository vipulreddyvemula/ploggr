import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'field_update_controller.dart';

class FieldUpdateSettings extends ConsumerWidget {
  const FieldUpdateSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(fieldUpdateProvider);
    final controller = ref.read(fieldUpdateProvider.notifier);
    final installed = status.installedBuild;
    final available = status.release?.buildNumber;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('App updates', style: Theme.of(context).textTheme.titleMedium),
          if (installed != null) Text('Installed build: Field $installed'),
          if (available != null) Text('Field $available is available'),
          if (status.message != null) Text(status.message!),
          if (status.updating) ...[
            const SizedBox(height: 8),
            _DownloadProgress(status.progress),
          ],
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: status.checking || status.updating
                    ? null
                    : () => controller.check(),
                child: Text(
                  status.checking ? 'Checking…' : 'Check for updates',
                ),
              ),
              if (available != null)
                FilledButton(
                  onPressed: status.checking || status.updating
                      ? null
                      : controller.update,
                  child: const Text('Update'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class FieldUpdateShell extends ConsumerStatefulWidget {
  const FieldUpdateShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FieldUpdateShell> createState() => _FieldUpdateShellState();
}

class _FieldUpdateShellState extends ConsumerState<FieldUpdateShell> {
  int? _dismissedBuild;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(fieldUpdateProvider);
    final available = status.release?.buildNumber;
    final showNotice = available != null && available != _dismissedBuild;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showNotice)
          Material(
            color: colors.secondaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Update available · Field $available',
                            style: TextStyle(
                              color: colors.onSecondaryContainer,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: status.updating || status.checking
                              ? null
                              : ref.read(fieldUpdateProvider.notifier).update,
                          child: const Text('Update'),
                        ),
                        IconButton(
                          tooltip: 'Dismiss update notice',
                          onPressed: status.updating
                              ? null
                              : () =>
                                    setState(() => _dismissedBuild = available),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    if (status.updating) _DownloadProgress(status.progress),
                    if (status.message != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          status.message!,
                          style: TextStyle(color: colors.onSecondaryContainer),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: showNotice,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress(this.progress);

  final double? progress;

  @override
  Widget build(BuildContext context) => LinearProgressIndicator(
    value: progress == 1 ? null : progress,
    semanticsLabel: 'Downloading and verifying the update',
  );
}
