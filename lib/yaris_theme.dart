import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class YarisTheme {
  static const canvas = Color(0xFFFAF9F4);
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF181B21);
  static const muted = Color(0xFF595F6C);
  static const blue = Color(0xFF3548E8);
  static const periwinkle = Color(0xFFE7EAFF);
  static const neutral = Color(0xFFEBE8DF);
  static const line = Color(0xFFE5E1D7);
  static const rose = Color(0xFFFBE0DF);
  static const red = Color(0xFFA82F36);

  static final light = ThemeData(
    useMaterial3: true,
    fontFamily: '.SF Pro Text',
    scaffoldBackgroundColor: canvas,
    colorScheme: const ColorScheme.light(
      primary: blue,
      onPrimary: Colors.white,
      primaryContainer: periwinkle,
      onPrimaryContainer: Color(0xFF243591),
      secondary: red,
      secondaryContainer: rose,
      onSecondaryContainer: red,
      surface: paper,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceContainerHighest: neutral,
      outlineVariant: line,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: ink,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: neutral,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );

  // The full-screen record player uses artwork as a dark, immersive canvas.
  static final player = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: '.SF Pro Text',
    colorScheme: const ColorScheme.dark(primary: Color(0xFFB8C1FF)),
  );
}
