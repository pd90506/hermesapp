import 'package:fluent_ui/fluent_ui.dart';

import '../app/app_state.dart';
import '../app/settings_store.dart';
import '../app/snapshots.dart';
import '../platform/system.dart';
import 'theme.dart';

/// The server form: the address and the sign-in, as the Mac's Settings > Servers.
/// On first run it is the whole window (`ConnectPage`); later it is the Servers page.
class ServerForm extends StatefulWidget {
  const ServerForm({super.key, required this.app, this.onConnected});
  final AppState app;
  final VoidCallback? onConnected;
  @override
  State<ServerForm> createState() => _ServerFormState();
}

class _ServerFormState extends State<ServerForm> {
  late final _url = TextEditingController(text: widget.app.settings.serverUrl);
  late final _username = TextEditingController(text: widget.app.settings.username);
  final _secret = TextEditingController();
  late SignIn _signIn = widget.app.settings.signIn;

  @override
  void initState() {
    super.initState();
    for (final c in [_url, _username, _secret]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_url, _username, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete =>
      _url.text.trim().isNotEmpty &&
      _secret.text.isNotEmpty &&
      (_signIn != SignIn.password || _username.text.trim().isNotEmpty);

  Future<void> _connect() async {
    final next = Settings(
      serverUrl: _url.text.trim(),
      signIn: _signIn,
      username: _username.text.trim(),
      theme: widget.app.settings.theme,
    );
    if (await widget.app.saveServerAndConnect(next, _secret.text) && mounted) {
      _secret.clear();
      widget.onConnected?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final app = widget.app;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      InfoLabel(label: 'Server URL', child: TextBox(controller: _url, placeholder: 'https://hermes.example.ts.net')),
      const SizedBox(height: 4),
      Text('The address of your Hermes dashboard (the same one the desktop app uses), e.g. a Tailscale HTTPS name.',
          style: TextStyle(fontSize: 12, color: p.text2)),
      const SizedBox(height: 16),
      InfoLabel(
        label: 'Sign-in method',
        child: ComboBox<SignIn>(
          value: _signIn,
          isExpanded: true,
          items: [for (final s in SignIn.values) ComboBoxItem(value: s, child: Text(s.label))],
          onChanged: (s) => setState(() => _signIn = s ?? _signIn),
        ),
      ),
      if (_signIn == SignIn.password) ...[
        const SizedBox(height: 16),
        InfoLabel(label: 'Username', child: TextBox(controller: _username)),
      ],
      const SizedBox(height: 16),
      InfoLabel(
        label: switch (_signIn) {
          SignIn.password => 'Password',
          SignIn.accessToken => 'Access token',
          SignIn.sessionToken => 'Session token',
        },
        child: PasswordBox(controller: _secret, revealMode: PasswordRevealMode.peek),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Icon(Glyphs.lock, size: 12, color: p.text2),
        const SizedBox(width: 8),
        Text('Saved in Windows Credential Manager', style: TextStyle(fontSize: 12, color: p.text2)),
      ]),
      if (app.error case final error? when !app.isConnecting) ...[
        const SizedBox(height: 16),
        InfoBar(
          title: const Text('Couldn\'t connect'),
          content: Text(error),
          severity: InfoBarSeverity.error,
          onClose: app.dismissError,
        ),
      ],
      const SizedBox(height: 20),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (app.isConnecting) ...[
          const SizedBox(width: 16, height: 16, child: ProgressRing(strokeWidth: 2)),
          const SizedBox(width: 12),
        ],
        FilledButton(onPressed: _complete && !app.isConnecting ? _connect : null, child: const Text('Connect')),
      ]),
    ]);
  }
}

/// First run: the server form on its own, as Windows apps welcome you.
class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Container(
          width: 460,
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 28),
          decoration: BoxDecoration(
            color: p.layer,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.cardStroke),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Connect to Hermes',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: p.text, height: 1.2)),
            const SizedBox(height: 20),
            ServerForm(app: app),
          ]),
        ),
      ),
    );
  }
}

/// Settings, as the Windows Settings app lays it out: a navigation list on Mica and
/// a page of setting cards on the layer. The Mac app's other panes (Providers,
/// Capabilities, Session sources, Notifications) come with the features behind them.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});
  final AppState app;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final pages = [
      (Glyphs.server, 'Servers'),
      (Glyphs.color, 'Appearance'),
    ];
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 280,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Column(children: [
            for (final (i, page) in pages.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _NavItem(icon: page.$1, label: page.$2, selected: i == _page, onPressed: () => setState(() => _page = i)),
              ),
          ]),
        ),
      ),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: p.layer,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(8)),
            border: Border(top: BorderSide(color: p.layerStroke), left: BorderSide(color: p.layerStroke)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(40, 26, 40, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(pages[_page].$2, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: p.text)),
                const SizedBox(height: 22),
                if (_page == 0) _ServersPage(app: widget.app) else _AppearancePage(app: widget.app),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onPressed});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return HoverButton(
      onPressed: onPressed,
      builder: (context, states) => Container(
        height: 36,
        decoration: BoxDecoration(
          color: selected || states.isHovered ? p.subtle : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(color: selected ? p.accent : null, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 13),
          Icon(icon, size: 16, color: p.text),
          const SizedBox(width: 16),
          Text(label, style: TextStyle(fontSize: 14, color: p.text)),
        ]),
      ),
    );
  }
}

/// A setting card, as the Windows Settings app's: icon, title and description, the
/// control at the end.
class SettingCard extends StatelessWidget {
  const SettingCard({super.key, required this.icon, required this.title, this.description, this.trailing});
  final IconData icon;
  final String title;
  final String? description;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.cardStroke),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: p.text),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 14, color: p.text)),
            if (description != null) Text(description!, style: TextStyle(fontSize: 12, color: p.text2)),
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: 16), trailing!],
      ]),
    );
  }
}

class _ServersPage extends StatelessWidget {
  const _ServersPage({required this.app});
  final AppState app;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final state = app.connection.state;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (app.settings.hasServer)
        SettingCard(
          icon: Glyphs.globe,
          title: app.settings.serverUrl,
          description: switch (state) {
            LinkState.connected => 'Connected',
            LinkState.connecting => 'Connecting…',
            LinkState.reconnecting => 'Reconnecting (attempt ${app.connection.detail ?? '1'})…',
            LinkState.failed => app.connection.detail ?? 'Couldn\'t connect',
            LinkState.disconnected => 'Not connected',
          },
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (state == LinkState.connected)
              Button(onPressed: app.disconnect, child: const Text('Disconnect'))
            else
              Button(onPressed: app.connectSaved, child: const Text('Connect')),
            const SizedBox(width: 8),
            Button(onPressed: app.removeServer, child: const Text('Remove')),
          ]),
        ),
      const SizedBox(height: 18),
      Text(app.settings.hasServer ? 'Change the server or sign-in' : 'Add a server',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.text)),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.cardStroke),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: 460, child: ServerForm(app: app)),
        ),
      ),
    ]);
  }
}

class _AppearancePage extends StatelessWidget {
  const _AppearancePage({required this.app});
  final AppState app;
  @override
  Widget build(BuildContext context) {
    return SettingCard(
      icon: Glyphs.color,
      title: 'App theme',
      description: 'Select which app theme to display',
      trailing: SizedBox(
        width: 200,
        child: ComboBox<AppTheme>(
          value: app.settings.theme,
          isExpanded: true,
          items: const [
            ComboBoxItem(value: AppTheme.light, child: Text('Light')),
            ComboBoxItem(value: AppTheme.dark, child: Text('Dark')),
            ComboBoxItem(value: AppTheme.system, child: Text('Use system setting')),
          ],
          onChanged: (t) => app.setTheme(t ?? AppTheme.system),
        ),
      ),
    );
  }
}
