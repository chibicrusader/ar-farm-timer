import 'package:flutter/material.dart';

import '../models/farm_item.dart';
import '../models/farm_timer.dart';

/// Dark, parchment-and-gold palette loosely inspired by ArcheAge's UI.
class AppColors {
  static const background = Color(0xFF12161C);
  static const surface = Color(0xFF1B2129);
  static const surfaceHigh = Color(0xFF242C36);
  static const gold = Color(0xFFC9A45C);
  static const goldDim = Color(0xFF8C7340);
  static const parchment = Color(0xFFE8DCC2);
  static const growing = Color(0xFF6FA3C7);
  static const ready = Color(0xFF7CC47A);
  static const overdue = Color(0xFFD9644E);

  static Color forStatus(TimerStatus s) => switch (s) {
    TimerStatus.growing => growing,
    TimerStatus.ready => ready,
    TimerStatus.overdue => overdue,
  };
}

IconData categoryIcon(FarmCategory c) => switch (c) {
  FarmCategory.crops => Icons.grass,
  FarmCategory.trees => Icons.park,
  FarmCategory.livestock => Icons.pets,
  FarmCategory.other => Icons.category,
};

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.gold, brightness: Brightness.dark).copyWith(
    primary: AppColors.gold,
    onPrimary: const Color(0xFF231A08),
    secondary: AppColors.goldDim,
    surface: AppColors.surface,
    onSurface: AppColors.parchment,
    surfaceContainerHighest: AppColors.surfaceHigh,
    error: AppColors.overdue,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.gold,
      centerTitle: false,
      elevation: 0,
      titleTextStyle: TextStyle(color: AppColors.gold, fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 1.2),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0x33C9A45C)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: Color(0x55C9A45C),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: Color(0x55C9A45C),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: TextStyle(color: AppColors.parchment),
      actionTextColor: AppColors.gold,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
