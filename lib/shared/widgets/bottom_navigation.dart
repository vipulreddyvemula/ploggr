import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../routes/auth_navigation.dart';
import 'package:material_ui/material_ui.dart';
import '../../routes/app_routes.dart';
import 'ploggr_ui.dart';

class BottomNavBar extends ConsumerWidget {
  const BottomNavBar({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(authModeProvider) == AuthMode.live;
    final router = GoRouter.maybeOf(context);
    final path =
        router != null && router.routerDelegate.currentConfiguration.isNotEmpty
        ? router.state.uri.path
        : '';
    final destination = switch (path) {
      AppRoutes.home => AppRoutes.home,
      AppRoutes.map => AppRoutes.map,
      AppRoutes.scan || AppRoutes.report => AppRoutes.report,
      _ when path.startsWith('${AppRoutes.community}/') => AppRoutes.community,
      _ when path.startsWith('${AppRoutes.profile}/') => AppRoutes.profile,
      _ => path,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(top: BorderSide(color: context.colors.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  _item(
                    context,
                    destination,
                    'Home',
                    Icons.home_outlined,
                    Icons.home_rounded,
                    AppRoutes.home,
                  ),
                  _item(
                    context,
                    destination,
                    live ? 'Map' : 'Explore',
                    Icons.search_rounded,
                    Icons.search_rounded,
                    AppRoutes.map,
                  ),
                  if (live)
                    _item(
                      context,
                      destination,
                      'Report',
                      Icons.add_location_alt_outlined,
                      Icons.add_location_alt,
                      AppRoutes.report,
                    )
                  else
                    Expanded(
                      child: Center(
                        heightFactor: 1,
                        child: IconButton.filled(
                          tooltip: 'Create a litter report',
                          onPressed: () => openPage(context, AppRoutes.scan),
                          icon: const Icon(Icons.add_rounded, size: 28),
                        ),
                      ),
                    ),
                  _item(
                    context,
                    destination,
                    'Community',
                    Icons.diversity_3_outlined,
                    Icons.diversity_3_rounded,
                    AppRoutes.community,
                  ),
                  _item(
                    context,
                    destination,
                    'Profile',
                    Icons.person_outline_rounded,
                    Icons.person_rounded,
                    AppRoutes.profile,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context,
    String destination,
    String label,
    IconData icon,
    IconData active,
    String route,
  ) {
    final selected = destination == route;
    final color = selected
        ? context.colors.onPrimaryContainer
        : context.colors.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          borderRadius: AppRadius.small,
          onTap: selected ? () {} : () => switchPage(context, route),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSpace.target),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: AppRadius.pill,
                      color: selected
                          ? context.colors.primaryContainer
                          : Colors.transparent,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        selected ? active : icon,
                        color: color,
                        size: 23,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
