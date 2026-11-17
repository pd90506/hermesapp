import 'package:fluent_ui/fluent_ui.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'common.dart';
import 'theme.dart';

/// The profiles, as the Mac app's rail: a circle each, a rounded square and the accent
/// pill when selected; Settings at the bottom.
class ProfileRail extends StatelessWidget {
  const ProfileRail({super.key, required this.app});
  final AppState app;

  static const width = 56.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [for (final bot in app.connection.bots) _RailItem(app: app, bot: bot)],
          ),
        ),
        IconAction(Glyphs.settings, tooltip: 'Settings', onPressed: () => app.showSettings(true)),
        const SizedBox(height: 8),
      ]),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.app, required this.bot});
  final AppState app;
  final Bot bot;

  /// A colour per profile, steady across launches.
  static const _colors = [
    Color(0xFF8764B8),
    Color(0xFF0078D4),
    Color(0xFFCA5010),
    Color(0xFF498205),
    Color(0xFFC239B3),
    Color(0xFF038387),
  ];

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final selected = app.selectedProfile == bot.name;
    final color = _colors[bot.name.codeUnits.fold(0, (a, b) => a + b) % _colors.length];
    final initial = bot.displayName.isEmpty ? '?' : bot.displayName.characters.first.toUpperCase();
    return Tooltip(
      message: bot.displayName,
      child: HoverButton(
        onPressed: () => app.selectProfile(bot.name),
        builder: (context, states) => SizedBox(
          height: 48,
          child: Stack(alignment: Alignment.center, children: [
            Positioned(
              left: 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 167),
                width: 3,
                height: selected ? 18 : (states.isHovered ? 8 : 0),
                decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 167),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(selected || states.isHovered ? 8 : 18),
              ),
              alignment: Alignment.center,
              child: Text(initial,
                  style: const TextStyle(color: Color(0xFFFFFFFF), fontWeight: FontWeight.w600, fontSize: 14)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The selected profile's Bot Chat and sessions, with New chat and the connection's
/// state, as the Mac's session list.
class SessionPane extends StatelessWidget {
  const SessionPane({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final profile = app.selectedProfile;
    final bot = app.connection.bots.where((b) => b.name == profile).firstOrNull;
    final sessions = app.connection.sessions.where((s) => s.profile == profile).toList();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(bot?.displayName ?? 'Talaria',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: p.text, height: 1.25)),
                Text(_status(app),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.text2)),
              ]),
            ),
            IconAction(Glyphs.compose,
                tooltip: 'New chat (Ctrl+N)', onPressed: profile == null ? null : () => app.newChat()),
          ]),
        ),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            if (bot != null) ...[
              const _Header('Bot Chat'),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: ListItem(
                  selected: app.selectedRow == 'bot:${bot.name}',
                  height: 48,
                  onPressed: () => app.openBotChat(bot.name),
                  child: _TwoLines(title: bot.displayName, subtitle: bot.preview ?? 'Say hello'),
                ),
              ),
            ],
            const _Header('Sessions'),
            if (app.connection.sessionListLoading && sessions.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: ProgressRing()))
            else if (app.connection.sessionListError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Text(error, style: TextStyle(fontSize: 12, color: p.text2)),
              )
            else if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Text('No sessions yet', style: TextStyle(fontSize: 12, color: p.text2)),
              ),
            for (final s in sessions)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: ListItem(
                  // Or the open chat's own row, once a new chat has one.
                  selected: app.selectedRow == s.id ||
                      (app.selectedRow == null && s.storedID != null && s.storedID == app.chat.storedSessionID),
                  height: 48,
                  onPressed: () => app.openSession(s),
                  child: _TwoLines(
                    title: (s.title?.isNotEmpty ?? false) ? s.title! : 'Untitled chat',
                    subtitle: s.startedAt == null ? '' : relativeTime(s.startedAt!),
                    bold: s.isUnread,
                    trailing: app.chat.isRunning && app.chat.storedSessionID == s.storedID
                        ? const SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2))
                        : s.isUnread
                            ? Container(
                                width: 8, height: 8, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle))
                            : null,
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  static String _status(AppState app) => switch (app.connection.state) {
        LinkState.connected => app.settings.serverUrl.replaceFirst(RegExp(r'^https?://'), ''),
        LinkState.connecting => 'Connecting…',
        LinkState.reconnecting => 'Reconnecting…',
        LinkState.failed => 'Couldn\'t connect',
        LinkState.disconnected => 'Not connected',
      };
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
        child: Text(text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: PaletteScope.of(context).text2)),
      );
}

class _TwoLines extends StatelessWidget {
  const _TwoLines({required this.title, required this.subtitle, this.bold = false, this.trailing});
  final String title, subtitle;
  final bool bold;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Row(children: [
      const SizedBox(width: 9),
      Expanded(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: p.text, fontWeight: bold ? FontWeight.w600 : FontWeight.w400, height: 1.3)),
          if (subtitle.isNotEmpty)
            Text(subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.text2, height: 1.3)),
        ]),
      ),
      ?trailing,
      const SizedBox(width: 10),
    ]);
  }
}

/// "Now", "5 minutes ago", "Yesterday", or the date: as Windows' own lists say it.
String relativeTime(DateTime date, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final age = reference.difference(date);
  if (age.inMinutes < 1) return 'Now';
  if (age.inMinutes < 60) return '${age.inMinutes} minute${age.inMinutes == 1 ? '' : 's'} ago';
  if (age.inHours < 24 && date.day == reference.day) {
    return '${age.inHours} hour${age.inHours == 1 ? '' : 's'} ago';
  }
  final yesterday = DateTime(reference.year, reference.month, reference.day - 1);
  if (!date.isBefore(yesterday)) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final day = '${months[date.month - 1]} ${date.day}';
  return date.year == reference.year ? day : '$day, ${date.year}';
}
