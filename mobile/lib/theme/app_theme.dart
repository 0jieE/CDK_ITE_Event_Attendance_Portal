import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Brand theme — the Colegio de Kidapawan ITE seal green (#41B422), Material 3.
///
/// Accessibility rules (same as the web portal):
///  * Text/icons on a SOLID [green] fill use [onGreen] (very dark green ink);
///    white on #41B422 is only ~2.7:1.
///  * Green used as TEXT or an accent on a light surface uses [greenText]
///    (#2B8416, >= 4.5:1), never the bright [green].
///  * Hover / pressed state of a green fill is [greenPressed].
class AppTheme {
  AppTheme._();

  // --- Brand tokens ---------------------------------------------------------
  static const Color green = Color(0xFF41B422);
  static const Color greenPressed = Color(0xFF379C1C);
  static const Color greenText = Color(0xFF2B8416);
  static const Color onGreen = Color(0xFF06200A);
  static const Color greenTint = Color(0xFFE7F6E2);
  static const Color greenTintInk = Color(0xFF0F3D08);

  static const Color ink = Color(0xFF17231A);
  static const Color muted = Color(0xFF5B6B5F);
  static const Color background = Color(0xFFF3F6F3);

  /// rgba(20, 35, 22, 0.10) — hairline borders.
  static const Color border = Color(0x1A142316);

  static const Color danger = Color(0xFFB02A37);
  static const Color dangerTint = Color(0xFFFDE7E9);

  // Dark-mode counterparts.
  static const Color _darkBackground = Color(0xFF0E140F);
  static const Color _darkSurface = Color(0xFF18211A);
  static const Color _darkAccent = Color(0xFF7BD95F);
  static const Color _darkMuted = Color(0xFFA3B2A6);
  static const Color _darkInk = Color(0xFFE8F0E9);
  static const Color _darkBorder = Color(0x1FFFFFFF);

  static const double radiusCard = 16;
  static const double radiusControl = 12;

  /// Full-width filled button (forms / primary actions).
  static final ButtonStyle wide =
      FilledButton.styleFrom(minimumSize: const Size.fromHeight(50));

  static const BrandColors _lightBrand = BrandColors(
    accent: greenText,
    tint: greenTint,
    border: border,
    muted: muted,
    presentBg: Color(0xFFE3F5DC),
    presentFg: Color(0xFF1E6B0F),
    lateBg: Color(0xFFFFF1D6),
    lateFg: Color(0xFF8A5A00),
    absentBg: dangerTint,
    absentFg: danger,
    neutralBg: Color(0xFFE9EEE9),
    neutralFg: muted,
  );

  static const BrandColors _darkBrand = BrandColors(
    accent: _darkAccent,
    tint: Color(0xFF1F3A21),
    border: _darkBorder,
    muted: _darkMuted,
    presentBg: Color(0xFF1F3A21),
    presentFg: Color(0xFF8FE274),
    lateBg: Color(0xFF3F3014),
    lateFg: Color(0xFFFFCB66),
    absentBg: Color(0xFF42191D),
    absentFg: Color(0xFFFF9BA4),
    neutralBg: Color(0xFF252F27),
    neutralFg: _darkMuted,
  );

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final brand = isLight ? _lightBrand : _darkBrand;
    final surface = isLight ? Colors.white : _darkSurface;
    final bg = isLight ? background : _darkBackground;
    final onSurface = isLight ? ink : _darkInk;
    final variant = isLight ? muted : _darkMuted;

    final scheme = ColorScheme.fromSeed(
      seedColor: green,
      brightness: brightness,
    ).copyWith(
      primary: green,
      onPrimary: onGreen,
      primaryContainer: brand.tint,
      onPrimaryContainer: isLight ? greenTintInk : const Color(0xFFBDF0AB),
      secondary: isLight ? greenText : _darkAccent,
      onSecondary: isLight ? Colors.white : onGreen,
      secondaryContainer: brand.tint,
      onSecondaryContainer: isLight ? greenTintInk : const Color(0xFFBDF0AB),
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: variant,
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
      surfaceContainerHighest: isLight ? const Color(0xFFE9EEE9) : const Color(0xFF252F27),
      outline: isLight ? const Color(0xFF8A988D) : const Color(0xFF6E7C71),
      outlineVariant: brand.border,
      error: isLight ? danger : const Color(0xFFFF9BA4),
      onError: isLight ? Colors.white : const Color(0xFF42191D),
      errorContainer: brand.absentBg,
      onErrorContainer: brand.absentFg,
    );

    final accent = brand.accent;
    final controlShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusControl));

    OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusControl),
          borderSide: BorderSide(color: c, width: w),
        );
    final fieldBorder = isLight ? const Color(0x33142316) : const Color(0x33FFFFFF);

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: surface,
      extensions: [brand],
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: onSurface, displayColor: onSurface),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: onSurface),
        systemOverlayStyle: isLight
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
        shape: Border(bottom: BorderSide(color: brand.border)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: isLight ? 1.5 : 0,
        shadowColor: const Color(0x2617231A),
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: BorderSide(color: brand.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(88, 50)),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: const WidgetStatePropertyAll(
              TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          foregroundColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.disabled)
                  ? onSurface.withValues(alpha: 0.38)
                  : onGreen),
          backgroundColor: WidgetStateProperty.resolveWith((s) {
            if (s.contains(WidgetState.disabled)) {
              return onSurface.withValues(alpha: 0.12);
            }
            if (s.contains(WidgetState.pressed) ||
                s.contains(WidgetState.hovered)) {
              return greenPressed;
            }
            return green;
          }),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, 48),
          foregroundColor: accent,
          shape: controlShape,
          side: BorderSide(color: fieldBorder),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: controlShape,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: onSurface),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: green,
        foregroundColor: onGreen,
        elevation: 3,
        extendedTextStyle: const TextStyle(fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: inputBorder(fieldBorder),
        enabledBorder: inputBorder(fieldBorder),
        focusedBorder: inputBorder(accent, 2),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error, 2),
        disabledBorder: inputBorder(brand.border),
        labelStyle: TextStyle(color: variant),
        floatingLabelStyle: TextStyle(color: accent, fontWeight: FontWeight.w600),
        helperStyle: TextStyle(color: variant),
        errorStyle: TextStyle(color: scheme.error),
        prefixIconColor: variant,
        suffixIconColor: variant,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: brand.tint,
        indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected)
                  ? (isLight ? greenTintInk : _darkAccent)
                  : variant,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 12,
              fontWeight: s.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? onSurface : variant,
            )),
      ),
      dividerTheme: DividerThemeData(color: brand.border, space: 1, thickness: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isLight ? ink : const Color(0xFF2B382D),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        actionTextColor: _darkAccent,
        shape: controlShape,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: TextStyle(
            color: onSurface, fontSize: 20, fontWeight: FontWeight.w700),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: brand.tint,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: TextStyle(
            color: isLight ? greenTintInk : _darkAccent,
            fontWeight: FontWeight.w600,
            fontSize: 12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? onGreen : null),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? green : null),
      ),
    );
  }

  /// Strong solid status colours (white text on top) for the scanner result
  /// card. Soft badges use [BrandColors.badge] instead.
  static Color statusColor(String status) {
    switch (status) {
      case 'PRESENT':
      case 'PAID':
        return greenText;
      case 'LATE':
        return const Color(0xFF9A5B00);
      case 'ABSENT':
      case 'UNPAID':
        return danger;
      default:
        return muted;
    }
  }
}

/// Semantic colours that differ between light and dark (reach them with
/// `context.brand`).
@immutable
class BrandColors extends ThemeExtension<BrandColors> {
  /// Green as text / icon / accent on a surface (>= 4.5:1).
  final Color accent;

  /// Soft green background.
  final Color tint;
  final Color border;

  /// Secondary text.
  final Color muted;
  final Color presentBg, presentFg;
  final Color lateBg, lateFg;
  final Color absentBg, absentFg;
  final Color neutralBg, neutralFg;

  const BrandColors({
    required this.accent,
    required this.tint,
    required this.border,
    required this.muted,
    required this.presentBg,
    required this.presentFg,
    required this.lateBg,
    required this.lateFg,
    required this.absentBg,
    required this.absentFg,
    required this.neutralBg,
    required this.neutralFg,
  });

  /// Soft pill colours for a status (PRESENT/LATE/ABSENT/PAID/UNPAID).
  ({Color bg, Color fg}) badge(String status) {
    switch (status) {
      case 'PRESENT':
      case 'PAID':
        return (bg: presentBg, fg: presentFg);
      case 'LATE':
        return (bg: lateBg, fg: lateFg);
      case 'ABSENT':
      case 'UNPAID':
        return (bg: absentBg, fg: absentFg);
      default:
        return (bg: neutralBg, fg: neutralFg);
    }
  }

  @override
  BrandColors copyWith({Color? accent, Color? tint, Color? border, Color? muted}) {
    return BrandColors(
      accent: accent ?? this.accent,
      tint: tint ?? this.tint,
      border: border ?? this.border,
      muted: muted ?? this.muted,
      presentBg: presentBg,
      presentFg: presentFg,
      lateBg: lateBg,
      lateFg: lateFg,
      absentBg: absentBg,
      absentFg: absentFg,
      neutralBg: neutralBg,
      neutralFg: neutralFg,
    );
  }

  @override
  BrandColors lerp(ThemeExtension<BrandColors>? other, double t) {
    if (other is! BrandColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return BrandColors(
      accent: l(accent, other.accent),
      tint: l(tint, other.tint),
      border: l(border, other.border),
      muted: l(muted, other.muted),
      presentBg: l(presentBg, other.presentBg),
      presentFg: l(presentFg, other.presentFg),
      lateBg: l(lateBg, other.lateBg),
      lateFg: l(lateFg, other.lateFg),
      absentBg: l(absentBg, other.absentBg),
      absentFg: l(absentFg, other.absentFg),
      neutralBg: l(neutralBg, other.neutralBg),
      neutralFg: l(neutralFg, other.neutralFg),
    );
  }
}

extension BrandThemeContext on BuildContext {
  BrandColors get brand => Theme.of(this).extension<BrandColors>()!;
}
