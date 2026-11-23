import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/network/protected_api.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../auth/session/session_controller.dart';

final fieldData = FutureProvider.autoDispose.family<Object?, String>((
  ref,
  path,
) {
  ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  final uri = Uri.parse(path);
  return ref
      .watch(protectedApiProvider)
      .request<Object>('GET', uri.path, queryParameters: uri.queryParameters);
}, retry: (_, _) => null);

class FieldData extends ConsumerWidget {
  const FieldData(this.path, this.render, {super.key});
  final String path;
  final Widget Function(dynamic data) render;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(fieldData(path))
      .when(
        data: (d) => render(d),
        loading: () => const AppLoading('Loading'),
        error: (error, _) => AppNotice(
          switch (error) {
            ProtectedApiFailure(status: null) =>
              'Check your connection and try again.',
            ProtectedApiFailure(status: 403) =>
              'You don’t have access to this content.',
            _ => 'Could not load this content.',
          },
          status: AppStatus.failure,
          actionLabel: 'Retry',
          onAction: () => ref.invalidate(fieldData(path)),
        ),
      );
}

class FieldAction extends StatefulWidget {
  const FieldAction(
    this.label,
    this.work, {
    super.key,
    this.icon,
    this.primary = false,
  });
  final Future<void> Function()? work;
  final bool primary;
  final String label;
  final IconData? icon;
  @override
  State<FieldAction> createState() => _FieldActionState();
}

class _FieldActionState extends State<FieldAction> {
  bool busy = false;
  String? error;
  Future<void> run() async {
    if (busy || widget.work == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.work!();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not save. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final callback = busy || widget.work == null ? null : run;
    final label = Text(
      busy ? 'Saving…' : widget.label,
      textAlign: TextAlign.center,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.primary)
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: callback, child: label),
          )
        else
          TextButton.icon(
            onPressed: callback,
            icon: widget.icon == null ? null : Icon(widget.icon),
            label: label,
          ),
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

Future<void> writeField(
  WidgetRef ref,
  String verb,
  String path, {
  Object? data,
  List<String> reload = const [],
}) async {
  final api = ref.read(protectedApiProvider);
  await api.request<Object>(verb, path, data: data);
  if (ref.context.mounted) {
    for (final key in reload) {
      ref.invalidate(fieldData(key));
    }
  }
}

String localDate(BuildContext context, Object? value, {bool time = false}) {
  final d = DateTime.tryParse(value.toString())?.toLocal();
  if (d == null) return '';
  final date = MaterialLocalizations.of(context).formatMediumDate(d);
  return time ? '$date · ${TimeOfDay.fromDateTime(d).format(context)}' : date;
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;
