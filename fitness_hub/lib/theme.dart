import 'package:flutter/material.dart';

/// Brand tokens (same values as the design page).
class Brand {
  static const mint = Color(0xFF36ECDE);
  static const navy = Color(0xFF00203F);
  static const softGray = Color(0xFFE6E9EC);
  static const graphite = Color(0xFF2F2F2F);
  static const bg = Color(0xFFF5F7F9);
  static const ok = Color(0xFF0A9F6E);
  static const warn = Color(0xFFC27A00);
  static const bad = Color(0xFFD03B3B);
}

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Brand.navy,
    onPrimary: Colors.white,
    secondary: Brand.mint,
    onSecondary: Brand.navy, // mint is always paired with navy text
    error: Brand.bad,
    onError: Colors.white,
    surface: Colors.white,
    onSurface: Brand.graphite,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.bg,
    // Once you add the ANREX font files to pubspec.yaml, uncomment:
    // fontFamily: 'ANREX',
    dividerColor: Brand.softGray,
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Brand.softGray),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.mint,
        foregroundColor: Brand.navy,
        minimumSize: const Size(0, 44),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}