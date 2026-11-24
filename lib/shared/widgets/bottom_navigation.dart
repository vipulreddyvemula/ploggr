import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import '../../routes/app_routes.dart';
import 'ploggr_ui.dart';

class BottomNavBar extends StatelessWidget {
  const BottomNavBar({super.key});

  @override
  Widget build(BuildContext context) {
    final route = GoRouterState.of(context).uri.path;
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  for (final (label, path, icon, active) in const [
                    (
                      'Home',
                      AppRoutes.home,
                      Icons.home_outlined,
                      Icons.home_rounded,
                    ),
                    ('Map', AppRoutes.map, Icons.map_outlined, Icons.map),
                    (
                      'Community',
                      AppRoutes.community,
                      Icons.groups_outlined,
                      Icons.groups,
                    ),
                    (
                      'Profile',
                      AppRoutes.profile,
                      Icons.person_outline_rounded,
                      Icons.person,
                    ),
                  ])
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final selected =
                              route == path || route.startsWith('$path/');
                          final ink = selected
                              ? context.colors.onPrimaryContainer
                              : context.colors.onSurfaceVariant;
                          return Semantics(
                            selected: selected,
                            button: true,
                            child: Material(
                              color: selected
                                  ? context.colors.primaryContainer
                                  : Colors.transparent,
                              borderRadius: AppRadius.pill,
                              child: InkWell(
                                borderRadius: AppRadius.pill,
                                onTap: () {
                                  if (!selected || route != path) {
                                    switchPage(context, path);
                                  }
                                },
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 48,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        selected ? active : icon,
                                        size: 23,
                                        color: ink,
                                      ),
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          label,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: ink,
                                            fontWeight: selected
                                                ? FontWeight.w800
                                                : FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
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
