import 'package:fluent_ui/fluent_ui.dart';

import 'theme.dart';

/// The 48 px band Windows 11 apps draw into (WinUI's ExtendsContentIntoTitleBar):
/// a leading control (the pane toggle or Back), the app's icon and name. Its empty
/// space moves the window; Windows draws the caption buttons at its right
/// (`windows/runner/native_frame.cpp`), so nothing is placed there.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key, required this.title, this.leading});
  final String title;
  final Widget? leading;

  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return SizedBox(
      height: height,
      child: Row(children: [
        const SizedBox(width: 4),
        SizedBox(width: 40, child: leading),
        const SizedBox(width: 8),
        AppMark(size: 16, color: p.accent, onColor: p.onAccent),
        const SizedBox(width: 12),
        Text(title, style: TextStyle(fontSize: 12, color: p.text)),
      ]),
    );
  }
}

/// A stand-in for the app icon until there is a Windows one.
class AppMark extends StatelessWidget {
  const AppMark({super.key, required this.size, required this.color, required this.onColor});
  final double size;
  final Color color, onColor;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size / 4)),
        alignment: Alignment.center,
        child: Text('T', style: TextStyle(color: onColor, fontSize: size * 0.62, fontWeight: FontWeight.w700, height: 1)),
      );
}

/// A subtle icon button with a tooltip, as WinUI's AppBarButton without a label.
class IconAction extends StatelessWidget {
  const IconAction(this.icon, {super.key, required this.tooltip, this.onPressed, this.size = 16});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: IconButton(
          icon: Icon(icon, size: size),
          onPressed: onPressed,
          style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.all(8))),
        ),
      );
}

/// A list item as WinUI's ListView and NavigationView draw it: a rounded fill on hover
/// and while selected, and the accent pill at its leading edge when selected.
class ListItem extends StatelessWidget {
  const ListItem({super.key, required this.selected, required this.child, required this.onPressed, this.height});
  final bool selected;
  final Widget child;
  final VoidCallback onPressed;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return HoverButton(
      onPressed: onPressed,
      builder: (context, states) {
        final fill = selected || states.isHovered
            ? (states.isPressed ? p.subtle2 : p.subtle)
            : const Color(0x00000000);
        return Container(
          height: height,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(4)),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 167),
              width: 3,
              height: selected ? 16 : 0,
              decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(2)),
            ),
            Expanded(child: child),
          ]),
        );
      },
    );
  }
}
