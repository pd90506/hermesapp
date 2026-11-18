import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:hermes_bridge/hermes_bridge.dart';

import 'app/app_state.dart';
import 'app/settings_store.dart';
import 'platform/cjk_fonts.dart';
import 'platform/system.dart';
import 'ui/chat.dart';
import 'ui/common.dart';
import 'ui/settings.dart';
import 'ui/sidebar.dart';
import 'ui/theme.dart';

/// Talaria for Windows: a Hermes client over the shared Swift core (`HermesKit`),
/// reached through `HermesBridge.dll` beside the exe (docs/desktop-bridge.md).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bridge = HermesBridge.open('$exeDir\\HermesBridge.dll');
  final app = AppState(bridge: bridge, store: SettingsStore());
  runApp(TalariaApp(app: app, accent: SystemAccent.read()));
  app.connectSaved();
}

class TalariaApp extends StatelessWidget {
  const TalariaApp({super.key, required this.app, required this.accent});
  final AppState app;
  final SystemAccent accent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final mode = switch (app.settings.theme) {
          AppTheme.light => ThemeMode.light,
          AppTheme.dark => ThemeMode.dark,
          AppTheme.system => ThemeMode.system,
        };
        // Chinese text in Chinese forms, not Yu Gothic's Japanese ones (platform/cjk_fonts.dart).
        final cjk = CjkFonts.pick(WidgetsBinding.instance.platformDispatcher.locales);
        TextStyle? withCjk(TextStyle? s) => s?.copyWith(fontFamilyFallback: cjk.fallback, locale: cjk.locale);
        FluentThemeData theme(Brightness b) => FluentThemeData(
              brightness: b,
              fontFamily: uiFont,
              typography: () {
                final t = Typography.fromBrightness(brightness: b);
                return Typography.raw(
                  display: withCjk(t.display),
                  titleLarge: withCjk(t.titleLarge),
                  title: withCjk(t.title),
                  subtitle: withCjk(t.subtitle),
                  bodyLarge: withCjk(t.bodyLarge),
                  bodyStrong: withCjk(t.bodyStrong),
                  body: withCjk(t.body),
                  caption: withCjk(t.caption),
                );
              }(),
              accentColor: AccentColor.swatch({'normal': b == Brightness.dark ? accent.dark : accent.light}),
              // Clear: Mica, which Windows draws behind the window, shows through.
              scaffoldBackgroundColor: const Color(0x00000000),
            );
        return FluentApp(
          title: 'Talaria',
          debugShowCheckedModeBanner: false,
          color: const Color(0x00000000),
          themeMode: mode,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: Builder(builder: (context) {
            final palette = Palette.of(FluentTheme.of(context).brightness, accent);
            return PaletteScope(
              palette: palette,
              child: DefaultTextStyle(
                style: TextStyle(
                    fontFamily: uiFont,
                    fontFamilyFallback: cjk.fallback,
                    locale: cjk.locale,
                    fontSize: 14,
                    color: palette.text,
                    height: 1.4),
                child: _Shortcuts(app: app, child: MainWindow(app: app)),
              ),
            );
          }),
        );
      },
    );
  }
}

/// The window's keyboard shortcuts, as Windows apps have them.
class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.app, required this.child});
  final AppState app;
  final Widget child;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): app.newChat,
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () => app.showSettings(true),
          const SingleActivator(LogicalKeyboardKey.escape): () => app.showSettings(false),
        },
        child: Focus(autofocus: true, child: child),
      );
}

class MainWindow extends StatefulWidget {
  const MainWindow({super.key, required this.app});
  final AppState app;
  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> {
  bool _railShown = true;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final p = PaletteScope.of(context);
    if (app.needsServer) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const WindowTitleBar(title: 'Talaria'),
        Expanded(child: ConnectPage(app: app)),
      ]);
    }
    if (app.isSettingsShown) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WindowTitleBar(
          title: 'Settings',
          leading: IconAction(Glyphs.back, tooltip: 'Back (Esc)', size: 12, onPressed: () => app.showSettings(false)),
        ),
        Expanded(child: SettingsPage(app: app)),
      ]);
    }
    // As the Mac's split view: the title bar (the rail toggle, the app's icon and name)
    // over the sidebar only, and the chat from the window's top edge, its title in the
    // title bar's band and the caption buttons over its corner.
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: (_railShown ? ProfileRail.width : 8) + 272,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // As the Mac's toolbar over the sidebar: the rail's toggle, the profile's name
          // and New chat at the column's end (the user, 2026-11-18).
          WindowTitleBar(
            title: app.connection.bots.where((b) => b.name == app.selectedProfile).firstOrNull?.displayName ??
                'Talaria',
            subtitle: SessionPane.status(app),
            leading: IconAction(
              Glyphs.menu,
              tooltip: _railShown ? 'Hide profiles' : 'Show profiles',
              onPressed: () => setState(() => _railShown = !_railShown),
            ),
            trailing: IconAction(Glyphs.compose,
                tooltip: 'New chat (Ctrl+N)', onPressed: app.selectedProfile == null ? null : app.newChat),
          ),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_railShown) ProfileRail(app: app) else const SizedBox(width: 8),
              SizedBox(width: 272, child: SessionPane(app: app)),
            ]),
          ),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_railShown) ProfileRail(app: app) else const SizedBox(width: 8),
              SizedBox(width: 272, child: SessionPane(app: app)),
            ]),
          ),
        ]),
      ),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: p.layer,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(8)),
            border: Border(left: BorderSide(color: p.layerStroke)),
          ),
          child: Stack(children: [
            Positioned.fill(child: ChatPane(app: app)),
            if (app.error case final error? when !app.isConnecting)
              Positioned(
                left: 16,
                right: 16,
                top: WindowTitleBar.height,
                child: InfoBar(
                    title: const Text('Something went wrong'),
                    content: Text(error),
                    severity: InfoBarSeverity.error,
                    onClose: app.dismissError),
              ),
          ]),
        ),
      ),
    ]);
  }
}
