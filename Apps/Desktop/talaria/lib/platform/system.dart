/// What the app reads from, and tells, Windows: the accent colour and the frame's
/// light/dark mode.
library;

import 'package:flutter/services.dart';

import 'win32.dart';

/// The Windows accent as WinUI uses it: `SystemAccentColorDark1` on light,
/// `SystemAccentColorLight2` on dark, from the palette Windows derives from the
/// user's accent (`Explorer\Accent\AccentPalette`, eight RGBA colours from Light3 to
/// Dark3). Windows' default blue when it can't be read.
class SystemAccent {
  const SystemAccent({required this.light, required this.dark});

  final Color light;
  final Color dark;

  static const fallback = SystemAccent(light: Color(0xFF005FB8), dark: Color(0xFF60CDFF));

  static SystemAccent read() {
    final palette = readUserRegistry(r'Software\Microsoft\Windows\CurrentVersion\Explorer\Accent', 'AccentPalette');
    if (palette == null || palette.length < 32) return fallback;
    Color at(int i) => Color.fromARGB(0xFF, palette[i * 4], palette[i * 4 + 1], palette[i * 4 + 2]);
    return SystemAccent(light: at(4), dark: at(1));
  }
}

/// The app's light/dark choice, as the Mac app's Appearance setting.
enum AppTheme { system, light, dark }

/// Tells the window frame (Mica and the caption buttons, drawn by Windows) the app's
/// light/dark choice (`windows/runner/native_frame.cpp`).
class WindowFrame {
  static const _channel = MethodChannel('talaria/window');

  static Future<void> setTheme(AppTheme theme) => _channel.invokeMethod('setTheme', theme.name);
}
