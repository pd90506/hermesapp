import 'package:fluent_ui/fluent_ui.dart';

import '../platform/system.dart';

/// Windows 11's colour resources (WinUI's theme dictionaries), light and dark: Mica
/// under the window, panes left clear on it, content on the translucent layer, cards
/// on that. The accent is the user's Windows accent.
class Palette {
  const Palette({
    required this.dark,
    required this.accent,
    required this.layer,
    required this.layerStroke,
    required this.card,
    required this.cardStroke,
    required this.subtle,
    required this.subtle2,
    required this.text,
    required this.text2,
    required this.text3,
    required this.onAccent,
    required this.divider,
    required this.codeBg,
    required this.inputFill,
    required this.inputStroke,
    required this.inputFocusedFill,
    required this.inputStrongStroke,
    required this.caution,
    required this.success,
  });

  final bool dark;
  final Color accent, layer, layerStroke, card, cardStroke, subtle, subtle2;
  final Color text, text2, text3, onAccent, divider, codeBg, inputFill, inputStroke;

  /// WinUI's text field: `ControlFillColorInputActive` while focused, and
  /// `ControlStrongStrokeColorDefault`, the line along its bottom edge.
  final Color inputFocusedFill, inputStrongStroke;
  final Color caution, success;

  /// Code colours by `CodeHighlighter` kind: Visual Studio Code's default Light+ and
  /// Dark+ themes, the colours Windows developers see in their editor.
  Color? code(String kind) => switch (kind) {
        'keyword' => dark ? const Color(0xFF569CD6) : const Color(0xFF0000FF),
        'string' => dark ? const Color(0xFFCE9178) : const Color(0xFFA31515),
        'comment' => dark ? const Color(0xFF6A9955) : const Color(0xFF008000),
        'number' => dark ? const Color(0xFFB5CEA8) : const Color(0xFF098658),
        'type' => dark ? const Color(0xFF4EC9B0) : const Color(0xFF267F99),
        'function' => dark ? const Color(0xFFDCDCAA) : const Color(0xFF795E26),
        'literal' => dark ? const Color(0xFF569CD6) : const Color(0xFF0000FF),
        _ => null,
      };

  /// The user's messages: the accent, faint.
  Color get userBubble => accent.withValues(alpha: dark ? 0.16 : 0.10);

  static Palette of(Brightness brightness, SystemAccent accent) => brightness == Brightness.dark
      ? Palette(
          dark: true,
          accent: accent.dark,
          layer: const Color(0x4C3A3A3A),
          layerStroke: const Color(0x19000000),
          card: const Color(0x0DFFFFFF),
          cardStroke: const Color(0x19000000),
          subtle: const Color(0x0FFFFFFF),
          subtle2: const Color(0x0AFFFFFF),
          text: const Color(0xFFFFFFFF),
          text2: const Color(0xC5FFFFFF),
          text3: const Color(0x87FFFFFF),
          onAccent: const Color(0xFF000000),
          divider: const Color(0x15FFFFFF),
          codeBg: const Color(0x0FFFFFFF),
          inputFill: const Color(0xFF2B2B2B),
          inputStroke: const Color(0x12FFFFFF),
          inputFocusedFill: const Color(0xFF1F1F1F),
          inputStrongStroke: const Color(0x8BFFFFFF),
          caution: const Color(0xFFFCE100),
          success: const Color(0xFF6CCB5F),
        )
      : Palette(
          dark: false,
          accent: accent.light,
          layer: const Color(0x80FFFFFF),
          layerStroke: const Color(0x0F000000),
          card: const Color(0xB3FFFFFF),
          cardStroke: const Color(0x0F000000),
          subtle: const Color(0x09000000),
          subtle2: const Color(0x06000000),
          text: const Color(0xE4000000),
          text2: const Color(0x9E000000),
          text3: const Color(0x72000000),
          onAccent: const Color(0xFFFFFFFF),
          divider: const Color(0x0F000000),
          codeBg: const Color(0x08000000),
          inputFill: const Color(0xFFFBFBFB),
          inputStroke: const Color(0x0F000000),
          inputFocusedFill: const Color(0xFFFFFFFF),
          inputStrongStroke: const Color(0x72000000),
          caution: const Color(0xFF9D5D00),
          success: const Color(0xFF0F7B0F),
        );
}

class PaletteScope extends InheritedWidget {
  const PaletteScope({super.key, required this.palette, required super.child});
  final Palette palette;

  static Palette of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PaletteScope>()!.palette;

  @override
  bool updateShouldNotify(PaletteScope old) => old.palette != palette;
}

const uiFont = 'Segoe UI Variable Text';
const monoFont = 'Cascadia Mono';

/// Segoe Fluent Icons, Windows 11's icon font (it ships with Windows).
abstract final class Glyphs {
  static const _f = 'Segoe Fluent Icons';
  static const menu = IconData(0xE700, fontFamily: _f);
  static const back = IconData(0xE72B, fontFamily: _f);
  static const settings = IconData(0xE713, fontFamily: _f);
  static const compose = IconData(0xE70F, fontFamily: _f);
  static const search = IconData(0xE721, fontFamily: _f);
  static const more = IconData(0xE712, fontFamily: _f);
  static const copy = IconData(0xE8C8, fontFamily: _f);
  static const delete = IconData(0xE74D, fontFamily: _f);
  static const refresh = IconData(0xE72C, fontFamily: _f);
  static const send = IconData(0xE724, fontFamily: _f);
  static const stop = IconData(0xE71A, fontFamily: _f);
  static const chevronDown = IconData(0xE70D, fontFamily: _f);
  static const chevronUp = IconData(0xE70E, fontFamily: _f);
  static const chevronRight = IconData(0xE76C, fontFamily: _f);
  static const checkMark = IconData(0xE73E, fontFamily: _f);
  static const warning = IconData(0xE7BA, fontFamily: _f);
  static const lock = IconData(0xE72E, fontFamily: _f);
  static const server = IconData(0xE968, fontFamily: _f);
  static const color = IconData(0xE790, fontFamily: _f);
  static const chat = IconData(0xE8BD, fontFamily: _f);
  static const tool = IconData(0xE90F, fontFamily: _f); // Repair
  static const lightbulb = IconData(0xEA80, fontFamily: _f);
  static const globe = IconData(0xE774, fontFamily: _f);
  static const checkbox = IconData(0xE739, fontFamily: _f);
  static const attach = IconData(0xE723, fontFamily: _f);
  static const document = IconData(0xE8A5, fontFamily: _f);
  static const photo = IconData(0xEB9F, fontFamily: _f);
  static const cancel = IconData(0xE711, fontFamily: _f);
  static const pin = IconData(0xE718, fontFamily: _f);
  static const unpin = IconData(0xE77A, fontFamily: _f);
  static const checkboxChecked = IconData(0xE73A, fontFamily: _f);
}
