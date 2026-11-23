import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../constants/app_colors.dart';
import 'app_tokens.dart';

abstract final class AppTheme {
  static final light = _build(
    ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: AppColors.paleGreen,
      onPrimaryContainer: AppColors.forest,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.muted,
      outline: const Color(0xFF737F72),
      outlineVariant: AppColors.border,
      surfaceContainerLow: AppColors.background,
      surfaceContainer: const Color(0xFFECF2E9),
    ),
  );

  static final dark = _build(
    ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
      primary: const Color(0xFF9CDBA5),
      onPrimary: const Color(0xFF12391E),
      primaryContainer: const Color(0xFF24482D),
      onPrimaryContainer: const Color(0xFFC9EBC9),
      surface: const Color(0xFF1A241D),
      onSurface: const Color(0xFFE6EFE4),
      onSurfaceVariant: const Color(0xFFB8C7B7),
      outline: const Color(0xFF899989),
      outlineVariant: const Color(0xFF455347),
      surfaceContainerLow: const Color(0xFF111A14),
      surfaceContainer: const Color(0xFF253129),
    ),
  );

  static SystemUiOverlayStyle systemBars(ColorScheme colors) {
    final dark = colors.brightness == Brightness.dark;
    return (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(
          systemNavigationBarColor: colors.surfaceContainerLow,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
        );
  }

  static ThemeData _build(ColorScheme colors) {
    final inputBorder = OutlineInputBorder(
      borderRadius: AppRadius.small,
      borderSide: BorderSide(color: colors.outline),
    );
    const controlShape = RoundedRectangleBorder(borderRadius: AppRadius.small);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      fontFamily: 'NunitoSans',
      scaffoldBackgroundColor: colors.surfaceContainerLow,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: TextTheme(
        headlineLarge: AppText.hero,
        headlineSmall: AppText.title,
        titleLarge: AppText.heading,
        titleMedium: AppText.label,
        bodyLarge: AppText.body,
        bodyMedium: AppText.body,
        bodySmall: AppText.caption.copyWith(color: colors.onSurfaceVariant),
      ).apply(bodyColor: colors.onSurface, displayColor: colors.onSurface),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surfaceContainerLow,
        foregroundColor: colors.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'NunitoSans',
          color: colors.onSurface,
          fontSize: AppText.pageTitleSize,
          fontWeight: FontWeight.w800,
          height: 1.2,
        ),
        systemOverlayStyle: systemBars(colors),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(AppSpace.target, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: controlShape,
          textStyle: const TextStyle(
            fontFamily: 'NunitoSans',
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.square(AppSpace.target),
          side: BorderSide(color: colors.outline),
          shape: controlShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size.square(AppSpace.target),
          textStyle: const TextStyle(
            fontFamily: 'NunitoSans',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AppSpace.target),
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: colors.outline),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.card),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        modalBackgroundColor: colors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface,
        contentPadding: const EdgeInsets.all(AppSpace.lg),
        hintStyle: TextStyle(color: colors.onSurfaceVariant),
        prefixIconColor: colors.onSurfaceVariant,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface),
        actionTextColor: colors.inversePrimary,
        shape: controlShape,
      ),
    );
  }
}
