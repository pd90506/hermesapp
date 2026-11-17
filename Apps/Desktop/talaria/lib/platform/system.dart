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

/// What the clipboard holds (`windows/runner/native_files.cpp`): its formats as
/// uniform type identifiers, its text and its files, for HermesKit's paste decision.
class ClipboardContents {
  const ClipboardContents({this.types = const [], this.text, this.files = const []});
  final List<String> types;
  final String? text;
  final List<String> files;
}

/// Files from Windows into the composer (`windows/runner/native_files.cpp`): the Open
/// dialog, the clipboard, and files dragged onto the window.
class NativeFiles {
  static const _channel = MethodChannel('talaria/window');

  /// The Open dialog, several files at a time; empty when cancelled.
  static Future<List<String>> pick() async =>
      ((await _channel.invokeMethod<List<Object?>>('pickFiles')) ?? const []).cast<String>();

  static Future<ClipboardContents> readClipboard() async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>('readClipboard') ?? const {};
    return ClipboardContents(
      types: ((map['types'] as List?) ?? const []).cast<String>(),
      text: map['text'] as String?,
      files: ((map['files'] as List?) ?? const []).cast<String>(),
    );
  }

  /// The clipboard's image in [type] (a uniform type identifier); null when it has none.
  static Future<Uint8List?> readClipboardImage(String type) =>
      _channel.invokeMethod<Uint8List>('readClipboardImage', type);

  /// Files dragged over the window: [onDrag] as a drag enters (true) and leaves or
  /// drops (false), [onDrop] with the dropped paths.
  static void listen({required void Function(bool) onDrag, required void Function(List<String>) onDrop}) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dragChanged':
          onDrag(call.arguments as bool? ?? false);
        case 'filesDropped':
          onDrop(((call.arguments as List?) ?? const []).cast<String>());
      }
      return null;
    });
  }
}
