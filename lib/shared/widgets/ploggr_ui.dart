import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_tokens.dart';
import '../../routes/app_routes.dart';

export '../../core/constants/app_colors.dart';
export '../../core/theme/app_tokens.dart';

class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.child,
    this.bottomNavigation,
    this.bottomAction,
    this.actions,
    this.tabHeader,
    this.scroll = true,
    this.padding = const EdgeInsets.fromLTRB(20, AppSpace.md, 20, AppSpace.xl),
    this.root = false,
    this.backTo = AppRoutes.home,
  });
  final String title;
  final Widget child;
  final Widget? bottomNavigation;
  final Widget? bottomAction;
  final List<Widget>? actions;
  final Widget? tabHeader;
  final bool scroll, root;
  final EdgeInsets padding;
  final String backTo;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final compactKeyboard =
        bottomAction != null &&
        keyboard > 0 &&
        MediaQuery.sizeOf(context).height - keyboard < 320;
    final router = GoRouter.maybeOf(context);
    final fallbackOnBack =
        !root &&
        router != null &&
        router.routerDelegate.currentConfiguration.isNotEmpty &&
        ModalRoute.canPopOf(context) == false &&
        router.state.uri.path != backTo;
    final titleScale =
        MediaQuery.textScalerOf(context).scale(AppText.pageTitleSize) /
        AppText.pageTitleSize;
    return PopScope(
      canPop: !fallbackOnBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop &&
            fallbackOnBack &&
            ModalRoute.isCurrentOf(context) == true) {
          switchPage(context, backTo);
        }
      },
      child: Scaffold(
        appBar: compactKeyboard || tabHeader != null
            ? null
            : AppBar(
                toolbarHeight: kToolbarHeight * titleScale.clamp(1.0, 2.0),
                automaticallyImplyLeading: false,
                leading: root
                    ? null
                    : IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back_rounded, size: 22),
                        onPressed: () => goBack(context, fallback: backTo),
                      ),
                title: Text(title, maxLines: 2, textAlign: TextAlign.center),
                actions: actions ?? (root ? null : [const SizedBox(width: 48)]),
              ),
        body: SafeArea(
          top: tabHeader != null,
          bottom: bottomNavigation == null && bottomAction == null,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: scroll
                  ? SingleChildScrollView(
                      key: const PageStorageKey('page-scroll'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: padding,
                      child: tabHeader == null
                          ? child
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [tabHeader!, child],
                            ),
                    )
                  : Padding(padding: padding, child: child),
            ),
          ),
        ),
        bottomNavigationBar: bottomAction == null
            ? (keyboard == 0 ? bottomNavigation : null)
            : Padding(
                padding: EdgeInsets.only(bottom: keyboard),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SafeArea(
                      top: false,
                      bottom: bottomNavigation == null,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: Padding(
                          padding: compactKeyboard
                              ? const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 2,
                                )
                              : const EdgeInsets.fromLTRB(20, 8, 20, 12),
                          child: compactKeyboard
                              ? Row(
                                  children: [
                                    IconButton(
                                      tooltip: 'Hide keyboard',
                                      icon: const Icon(
                                        Icons.keyboard_hide_outlined,
                                      ),
                                      onPressed: () => FocusManager
                                          .instance
                                          .primaryFocus
                                          ?.unfocus(),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(child: bottomAction!),
                                  ],
                                )
                              : bottomAction,
                        ),
                      ),
                    ),
                    if (bottomNavigation != null && keyboard == 0)
                      bottomNavigation!,
                  ],
                ),
              ),
      ),
    );
  }
}

// Transient feedback belongs to the originating screen. Clear it before
// navigation so it never covers controls (especially the camera shutter).
void openPage(BuildContext context, String location) {
  ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
  context.push(location);
}

void switchPage(BuildContext context, String location) {
  ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
  context.go(location);
}

void goBack(BuildContext context, {String fallback = AppRoutes.home}) {
  ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.maybePop();
  } else {
    GoRouter.maybeOf(context)?.go(fallback);
  }
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<void> previewNotice(
  BuildContext context,
  String title,
  String message,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    icon: Icon(Icons.eco_outlined, color: context.colors.primary, size: 32),
    title: Text(title),
    content: Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Got it'),
      ),
    ],
  ),
);

class PreviewNote extends StatelessWidget {
  const PreviewNote({
    super.key,
    this.text = 'Preview · sample data',
    this.light = false,
  });
  final String text;
  final bool light;
  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: AppText.caption.copyWith(
      fontSize: 11,
      color: light
          ? Colors.white.withValues(alpha: .85)
          : context.colors.onSurfaceVariant,
    ),
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 22),
            const SizedBox(width: 10),
          ],
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ],
      ),
    ),
  );
}

class EcoCard extends StatelessWidget {
  const EcoCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      borderRadius: AppRadius.card,
      boxShadow: AppShadows.soft,
    ),
    child: Material(
      color: color ?? context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.card,
        side: BorderSide(color: context.colors.outlineVariant, width: .7),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      top: trailing == null ? 20 : 10,
      bottom: trailing == null ? 10 : 4,
    ),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(text, style: AppText.heading.copyWith(fontSize: 18)),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

enum AppStatus { information, success, warning, pending, failure }

class AppNotice extends StatelessWidget {
  const AppNotice(
    this.message, {
    super.key,
    this.status = AppStatus.information,
    this.actionLabel,
    this.onAction,
  }) : assert((actionLabel == null) == (onAction == null));

  final String message;
  final AppStatus status;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dark = colors.brightness == Brightness.dark;
    final (icon, background, foreground) = switch (status) {
      AppStatus.information => (
        Icons.info_outline,
        colors.surfaceContainer,
        colors.onSurface,
      ),
      AppStatus.success => (
        Icons.check_circle_outline,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      AppStatus.warning => (
        Icons.warning_amber_rounded,
        dark ? const Color(0xFF463419) : const Color(0xFFFFEBC9),
        dark ? const Color(0xFFFFDB9C) : const Color(0xFF553708),
      ),
      AppStatus.pending => (
        Icons.schedule,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      AppStatus.failure => (
        Icons.error_outline,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: AppRadius.small,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Row(
              children: [
                Icon(icon, color: foreground, size: 20),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Semantics(
                    liveRegion: status != AppStatus.information,
                    child: Text(message, style: TextStyle(color: foreground)),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (onAction != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

class AppLoading extends StatelessWidget {
  const AppLoading(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
    child: LinearProgressIndicator(
      semanticsLabel: label,
      borderRadius: AppRadius.pill,
    ),
  );
}

class FilterTabs extends StatelessWidget {
  const FilterTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: context.colors.surfaceContainer,
      borderRadius: AppRadius.pill,
      border: Border.all(color: context.colors.outlineVariant),
    ),
    child: Row(
      children: List.generate(
        labels.length,
        (index) => Expanded(
          child: Semantics(
            selected: index == selected,
            child: Material(
              color: selected == index
                  ? context.colors.primary
                  : Colors.transparent,
              borderRadius: AppRadius.pill,
              child: InkWell(
                borderRadius: AppRadius.pill,
                onTap: () => onChanged(index),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 10,
                    ),
                    child: Center(
                      child: Text(
                        labels[index],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: selected == index
                              ? context.colors.onPrimary
                              : context.colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.color,
    this.onTap,
  });
  final String value;
  final String label;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => EcoCard(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, color: color ?? context.colors.primary, size: 23),
          const SizedBox(height: 7),
        ],
        Text(
          value,
          style: AppText.heading.copyWith(fontSize: 20),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(
            fontSize: 11,
            color: context.colors.onSurface,
          ),
        ),
      ],
    ),
  );
}

class AppField extends StatefulWidget {
  const AppField({
    super.key,
    required this.label,
    required this.icon,
    this.autofillHints,
    this.helper,
    this.controller,
    this.password = false,
    this.keyboardType,
    this.validator,
    this.onSubmitted,
    this.textInputAction = TextInputAction.next,
  });
  final String label;
  final IconData icon;
  final Iterable<String>? autofillHints;
  final String? helper;
  final TextEditingController? controller;
  final bool password;
  final TextInputType? keyboardType;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction textInputAction;
  @override
  State<AppField> createState() => _AppFieldState();
}

class _AppFieldState extends State<AppField> {
  bool hidden = true;
  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    autofillHints: widget.autofillHints,
    obscureText: widget.password && hidden,
    enableSuggestions: !widget.password,
    autocorrect: !widget.password,
    keyboardType: widget.keyboardType,
    textInputAction: widget.textInputAction,
    validator: widget.validator,
    onFieldSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      helperText: widget.helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
      prefixIcon: Icon(widget.icon, size: 21),
      suffixIcon: widget.password
          ? IconButton(
              tooltip: hidden
                  ? 'Show ${widget.label.toLowerCase()}'
                  : 'Hide ${widget.label.toLowerCase()}',
              onPressed: () => setState(() => hidden = !hidden),
              icon: Icon(
                hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
                color: context.colors.onSurfaceVariant,
              ),
            )
          : null,
    ),
  );
}

class LitterTypePicker extends StatelessWidget {
  const LitterTypePicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  static const types = [
    'Plastic',
    'Paper',
    'Glass',
    'Metal',
    'E-waste',
    'Other',
  ];
  final String? selected;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaled = MediaQuery.textScalerOf(context).scale(12);
      final columns = constraints.maxWidth < 420 && scaled > 19 ? 2 : 3;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: types
            .map(
              (type) => SizedBox(
                width:
                    (constraints.maxWidth - (columns - 1) * AppSpace.sm) /
                    columns,
                child: Semantics(
                  selected: selected == type,
                  child: Material(
                    color: selected == type
                        ? context.colors.primary
                        : context.colors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadius.pill,
                      side: BorderSide(color: context.colors.outlineVariant),
                    ),
                    child: InkWell(
                      borderRadius: AppRadius.pill,
                      onTap: onChanged == null ? null : () => onChanged!(type),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpace.sm),
                            child: Text(
                              type,
                              textAlign: TextAlign.center,
                              style: AppText.label.copyWith(
                                color: selected == type
                                    ? context.colors.onPrimary
                                    : context.colors.onSurface,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      );
    },
  );
}

class LitterPhoto extends StatelessWidget {
  const LitterPhoto({
    super.key,
    this.height,
    this.width,
    this.fit = BoxFit.cover,
  });
  final double? height;
  final double? width;
  final BoxFit fit;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: AppRadius.small,
    child: Image.asset(
      'assets/images/demo/litter.png',
      height: height,
      width: width,
      fit: fit,
      semanticLabel: 'Sample photograph of a plastic bottle on a woodland path',
    ),
  );
}
