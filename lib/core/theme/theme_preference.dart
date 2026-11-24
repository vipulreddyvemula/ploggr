import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(storageNamespace: 'ploggr_preferences'),
);
const _themeKey = 'ploggr.theme';

Future<ThemeMode> loadThemePreference() async {
  try {
    return await _storage.read(key: _themeKey) == 'dark'
        ? ThemeMode.dark
        : ThemeMode.light;
  } on Exception {
    return ThemeMode.light;
  } on UnsupportedError {
    return ThemeMode.light;
  }
}

final initialThemeModeProvider = Provider<ThemeMode>((ref) => ThemeMode.light);

final themePreferenceProvider =
    NotifierProvider<ThemePreference, ({ThemeMode mode, bool saving})>(
      ThemePreference.new,
    );

class ThemePreference extends Notifier<({ThemeMode mode, bool saving})> {
  @override
  ({ThemeMode mode, bool saving}) build() =>
      (mode: ref.watch(initialThemeModeProvider), saving: false);

  Future<bool> setDarkMode(bool enabled) async {
    final mode = enabled ? ThemeMode.dark : ThemeMode.light;
    if (state.saving || state.mode == mode) return true;

    state = (mode: mode, saving: true);
    try {
      await _storage.write(key: _themeKey, value: mode.name);
      return true;
    } on Exception {
      return false;
    } on UnsupportedError {
      return false;
    } finally {
      if (ref.mounted) {
        state = (mode: mode, saving: false);
      }
    }
  }
}
