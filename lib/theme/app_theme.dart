import 'package:flutter/material.dart';

class AppColors {
  // ── Primary Palette ──────────────────────────────────────────
  static const Color primary       = Color(0xFF7A4A3C); // Warm coffee
  static const Color primaryLight  = Color(0xFFA46B5A); // Lighter coffee
  static const Color primarySoft   = Color(0xFFF3E7E1); // Soft blush tint

  // ── Background ───────────────────────────────────────────────
  static const Color background    = Color(0xFFF6F1EB); // Warm beige/cream
  static const Color surface       = Color(0xFFFFFFFF); // Card white
  static const Color surfaceAlt    = Color(0xFFF7F2EC); // Slightly tinted white

  // ── Text ─────────────────────────────────────────────────────
  static const Color textPrimary   = Color(0xFF1C1C1C); // Near black
  static const Color textSecondary = Color(0xFF9E9E9E); // Medium gray
  static const Color textHint      = Color(0xFFBDBDBD); // Light gray

  // ── Border / Divider ─────────────────────────────────────────
  static const Color border        = Color(0xFFE6DFD7); // Warm border
  static const Color divider       = Color(0xFFEEEAE4);

  // ── Semantic ─────────────────────────────────────────────────
  static const Color success       = Color(0xFF4CAF50);
  static const Color warning       = Color(0xFFFF9800);
  static const Color error         = Color(0xFFE53935);

  // ── Favorite Color Swatches (Screen 7) ───────────────────────
  static const Color swatchBlack   = Color(0xFF2C2C2C);
  static const Color swatchWhite   = Color(0xFFF5F5F0);
  static const Color swatchNavy    = Color(0xFF2C3E6B);
  static const Color swatchBurgundy= Color(0xFF8B2635);
  static const Color swatchBeige   = Color(0xFFE8DCC8);
  static const Color swatchOlive   = Color(0xFF6B7C45);
  static const Color swatchBlush   = Color(0xFFF4A7B3);
  static const Color swatchTeal    = Color(0xFF2A8C7E);
}

class AppRadius {
  static const double xs   = 8.0;
  static const double sm   = 12.0;
  static const double md   = 16.0;
  static const double lg   = 20.0;
  static const double xl   = 24.0;
  static const double xxl  = 32.0;
  static const double full = 100.0; // pill shape
}

class AppSpacing {
  static const double xs  = 4.0;
  static const double sm  = 8.0;
  static const double md  = 16.0;
  static const double lg  = 24.0;
  static const double xl  = 32.0;
  static const double xxl = 48.0;
}

class AppTextStyles {
  // ── Display ──────────────────────────────────────────────────
  static const TextStyle displayLarge = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
    height: 1.2,
  );

  static const TextStyle displayMedium = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.3,
    height: 1.3,
  );

  // ── Headline ─────────────────────────────────────────────────
  static const TextStyle headlineLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.3,
  );

  static const TextStyle headlineMedium = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  static const TextStyle headlineSmall = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  // ── Body ─────────────────────────────────────────────────────
  static const TextStyle bodyLarge = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.5,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.5,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.4,
  );

  // ── Label ────────────────────────────────────────────────────
  static const TextStyle labelLarge = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.4,
  );

  static const TextStyle labelMedium = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    height: 1.4,
  );

  static const TextStyle labelSmall = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    height: 1.3,
  );

  // ── Button ───────────────────────────────────────────────────
  static const TextStyle button = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.surface,
    letterSpacing: 0.3,
  );
}

class AppTheme {
  // ── Private constructor (utility class) ──────────────────────
  AppTheme._();

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.light(
        primary:      AppColors.primary,
        onPrimary:    AppColors.surface,
        secondary:    AppColors.primaryLight,
        onSecondary:  AppColors.surface,
        surface:      AppColors.surface,
        onSurface:    AppColors.textPrimary,
        error:        AppColors.error,
      ),

      // ── AppBar ───────────────────────────────────────────────
      appBarTheme: const AppBarTheme(
        backgroundColor:  AppColors.background,
        foregroundColor:  AppColors.textPrimary,
        elevation:        0,
        scrolledUnderElevation: 0,
        centerTitle:      false,
        titleTextStyle: TextStyle(
          fontSize:   18,
          fontWeight: FontWeight.w700,
          color:      AppColors.textPrimary,
          fontFamily: 'ArefRuqaa',
        ),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),

      // ── ElevatedButton ───────────────────────────────────────
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor:  AppColors.primary,
          foregroundColor:  AppColors.surface,
          minimumSize:      const Size(double.infinity, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          elevation: 0,
          textStyle: AppTextStyles.button,
        ),
      ),

      // ── OutlinedButton ───────────────────────────────────────
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor:  AppColors.primary,
          minimumSize:      const Size(double.infinity, 54),
          side: const BorderSide(color: AppColors.primary, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: AppTextStyles.button.copyWith(color: AppColors.primary),
        ),
      ),

      // ── TextButton ───────────────────────────────────────────
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(
            fontSize:   13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // ── InputDecoration ──────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled:      true,
        fillColor:   AppColors.surface,
        hintStyle:   AppTextStyles.bodyMedium,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical:   AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.error),
        ),
      ),

      // ── Card ─────────────────────────────────────────────────
      cardTheme: CardThemeData(
        color:     AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        margin: EdgeInsets.zero,
      ),

      // ── BottomNavigationBar ───────────────────────────────────
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor:      AppColors.surface,
        selectedItemColor:    AppColors.primary,
        unselectedItemColor:  AppColors.textSecondary,
        selectedLabelStyle:   TextStyle(
          fontSize:   11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontSize:   11,
          fontWeight: FontWeight.w400,
        ),
        type:       BottomNavigationBarType.fixed,
        elevation:  8,
        showSelectedLabels:   true,
        showUnselectedLabels: true,
      ),

      // ── Chip ─────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        backgroundColor:     AppColors.surface,
        selectedColor:       AppColors.primary,
        labelStyle: const TextStyle(
          fontSize:   13,
          fontWeight: FontWeight.w500,
          color:      AppColors.textPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize:   13,
          fontWeight: FontWeight.w500,
          color:      AppColors.surface,
        ),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical:   AppSpacing.sm,
        ),
      ),

      // ── Divider ──────────────────────────────────────────────
      dividerTheme: const DividerThemeData(
        color:     AppColors.divider,
        thickness: 1,
        space:     0,
      ),
    );
  }
}
