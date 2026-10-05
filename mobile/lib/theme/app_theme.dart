import 'package:flutter/material.dart';

/// Institutional theme — Colegio de Kidapawan ITE violet accent.
class AppTheme {
  static const Color violet = Color(0xFF5B2A86);
  static const Color violetDark = Color(0xFF45206A);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: violet,
      primary: violet,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF5F3F9),
      appBarTheme: const AppBarTheme(
        backgroundColor: violet,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: violet,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        filled: true,
        fillColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
    );
  }

  /// Status colors shared across the student/instructor UIs.
  static Color statusColor(String status) {
    switch (status) {
      case 'PRESENT':
        return const Color(0xFF198754);
      case 'LATE':
        return const Color(0xFFFFC107);
      case 'PAID':
        return const Color(0xFF198754);
      case 'ABSENT':
      case 'UNPAID':
        return const Color(0xFFDC3545);
      default:
        return Colors.grey;
    }
  }
}
