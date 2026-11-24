import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/core/theme/theme_preference.dart';

Future<void> main() async {
  // Validate before creating the widget tree, even while using preview data.
  final config = AppConfig.fromEnvironment();
  WidgetsFlutterBinding.ensureInitialized();
  final theme = await loadThemePreference();
  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        initialThemeModeProvider.overrideWithValue(theme),
      ],
      child: const PloggrApp(),
    ),
  );
}
