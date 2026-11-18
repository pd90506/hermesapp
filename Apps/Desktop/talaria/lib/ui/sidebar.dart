import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'common.dart';
import 'cron.dart';
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

/// A profile in the rail, as the Mac's `ProfileRailItem`: its avatar (the image, or its
/// initials on its colour), a circle that turns into a rounded square when picked or
/// under the pointer, and the badge of what it is doing. Right-click for Change Avatar…
/// and Remove Avatar, as on the Mac.
class _RailItem extends StatefulWidget {
  const _RailItem({required this.app, required this.bot});
  final AppState app;
  final Bot bot;
  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  final _menu = FlyoutController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  void _showMenu(Offset position) {
    final bot = widget.bot;
    _menu.showFlyout(
      position: position,
      barrierColor: const Color(0x00000000),
      builder: (context) => MenuFlyout(items: [
        MenuFlyoutItem(
          leading: const Icon(Glyphs.photo),
          text: const Text('Change Avatar…'),
          onPressed: () => widget.app.changeAvatar(bot),
        ),
        if (bot.hasAvatar)
          MenuFlyoutItem(
            leading: const Icon(Glyphs.delete),
            text: const Text('Remove Avatar'),
            onPressed: () => widget.app.removeAvatar(bot),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final app = widget.app;
    final bot = widget.bot;
    final selected = app.selectedProfile == bot.name;
    return Tooltip(
      message: bot.displayName,
      child: FlyoutTarget(
        controller: _menu,
        child: GestureDetector(
          onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
          child: HoverButton(
            onPressed: () => app.selectProfile(bot.name),
            builder: (context, states) => SizedBox(
              height: 44,
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
                BotAvatar(
                  bot: bot,
                  image: app.avatar(bot),
                  size: 36,
                  squared: selected || states.isHovered,
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A profile's avatar, as the Mac's `BotAvatar`: its image, or its initials in white on
/// its colour (the one picked in Hermes Desktop, else one of eight by its name), with
/// the badge of what it is doing at the bottom right.
class BotAvatar extends StatelessWidget {
  const BotAvatar({super.key, required this.bot, required this.image, this.size = 36, this.squared = false});
  final Bot bot;
  final Future<Uint8List?> image;
  final double size;
  final bool squared;

  /// The Mac's fallback colours: the system's blue, purple, pink, orange, teal, indigo,
  /// green and brown.
  static const _palette = [
    Color(0xFF007AFF),
    Color(0xFFAF52DE),
    Color(0xFFFF2D55),
    Color(0xFFFF9500),
    Color(0xFF30B0C7),
    Color(0xFF5856D6),
    Color(0xFF34C759),
    Color(0xFFA2845E),
  ];

  /// Two words' first letters, else the name's first two, upper-cased.
  static String initials(String name) {
    final words = name.split(' ').where((w) => w.isNotEmpty).toList();
    final letters = words.length > 1
        ? words.take(2).map((w) => w.characters.first).join()
        : name.characters.take(2).toString();
    return letters.toUpperCase();
  }

  /// Steady across launches: the sum of the name's code points.
  static Color fallbackColor(String name) => _palette[name.runes.fold(0, (a, b) => a + b) % _palette.length];

  @override
  Widget build(BuildContext context) {
    final color = bot.avatarColor != null ? Color(0xFF000000 | bot.avatarColor!) : fallbackColor(bot.displayName);
    final radius = BorderRadius.circular(squared ? size * 0.3 : size / 2);
    final letters = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // SwiftUI's `.gradient`: the colour, a touch lighter at the top.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, const Color(0xFFFFFFFF), 0.12)!, color],
        ),
      ),
      child: Text(initials(bot.displayName),
          style: TextStyle(color: const Color(0xFFFFFFFF), fontWeight: FontWeight.w600, fontSize: size * 0.375)),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: radius),
            child: FutureBuilder<Uint8List?>(
              future: image,
              builder: (context, snapshot) => snapshot.data == null
                  ? letters
                  : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
        Positioned(right: -2, bottom: -2, child: _ActivityBadge(activity: bot.activity)),
      ]),
    );
  }
}

/// What the profile is doing, as the Mac's badge: a pulsing blue dot while it works, an
/// orange "!" while it waits for the user, a green dot when its Bot Chat was just active.
class _ActivityBadge extends StatefulWidget {
  const _ActivityBadge({required this.activity});
  final BotActivity activity;
  @override
  State<_ActivityBadge> createState() => _ActivityBadgeState();
}

class _ActivityBadgeState extends State<_ActivityBadge> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_ActivityBadge old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.activity == BotActivity.working) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget dot(double size, Color color) =>
        Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    switch (widget.activity) {
      case BotActivity.working:
        return FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0.35).animate(_pulse),
          child: dot(10, const Color(0xFF007AFF)),
        );
      case BotActivity.waitingForYou:
        return Container(
          width: 12,
          height: 12,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0xFFFF9500), shape: BoxShape.circle),
          child: const Text('!',
              style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 9, fontWeight: FontWeight.w700, height: 1)),
        );
      case BotActivity.recent:
        return dot(9, const Color(0xFF34C759));
      case BotActivity.idle:
        return const SizedBox.shrink();
    }
  }
}

/// The selected profile's Bot Chat and sessions, with New chat and the connection's
/// state, as the Mac's session list.
/// The profile's sessions or its cron jobs, as the Mac's two sidebar tabs
/// (`SessionListTabBar`), and the sessions list's search (Ctrl+F), as the Mac's
/// sidebar search: its results take the list's place while the field has text.
class SessionPane extends StatelessWidget {
  const SessionPane({super.key, required this.app, this.searchFocus});
  final AppState app;

  /// Focused by Ctrl+F, as the Mac's toolbar search (⌘F).
  final FocusNode? searchFocus;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final profile = app.selectedProfile;
    final bot = app.connection.bots.where((b) => b.name == profile).firstOrNull;
    final searching = app.searchText.trim().isNotEmpty;
    final sessions = app.connection.sessions.where((s) => s.profile == profile).toList();
    final pinned = sessions.where((s) => s.isPinned).toList();
    final others = sessions.where((s) => !s.isPinned).toList();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _SessionTabs(app: app),
        if (!app.isCronShown) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
            child: _SearchField(app: app, focus: searchFocus),
          ),
        ],
        if (app.isCronShown)
          Expanded(child: CronPane(app: app))
        else if (searching)
          Expanded(child: _SearchResults(app: app))
        else ...[
          // The Bot Chat pinned above the list, as the Mac's `PinnedBotChat`: it stays put
          // while the sessions scroll (the user, 2026-11-18).
          if (bot != null) ...[
            const _Header('Bot Chat', major: true),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ListItem(
                selected: app.selectedRow == 'bot:${bot.name}',
                height: 48,
                onPressed: () => app.openBotChat(bot.name),
                child: _TwoLines(title: bot.displayName, subtitle: bot.preview ?? 'Say hello'),
              ),
            ),
            // A line between the Bot Chat and the sessions (the user, 2026-11-18).
            Container(height: 1, margin: const EdgeInsets.fromLTRB(16, 10, 8, 0), color: p.divider),
          ],
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: [
              // Pinned sessions above the rest, while there are any, as on the Mac.
              if (pinned.isNotEmpty) ...[
                const _Header('Pinned', major: true),
                for (final s in pinned) _SessionRow(app: app, session: s),
              ],
              const _Header('Sessions', major: true),
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
              // The rest in Desktop's date groups (HermesKit's `sessionDateGroups`): the newest
              // run under "Sessions", then "Yesterday", "Last week", a month…
              for (final (i, s) in others.indexed) ...[
                if (i > 0 && s.group != others[i - 1].group && s.groupTitle != null) _Header(s.groupTitle!),
                _SessionRow(app: app, session: s),
              ],
            ]),
          ),
        ],
      ]),
    );
  }

  /// The connection, under the profile's name in the title bar.
  static String status(AppState app) => switch (app.connection.state) {
        LinkState.connected => app.settings.serverUrl.replaceFirst(RegExp(r'^https?://'), ''),
        LinkState.connecting => 'Connecting…',
        LinkState.reconnecting => 'Reconnecting…',
        LinkState.failed => 'Couldn\'t connect',
        LinkState.disconnected => 'Not connected',
      };
}

/// A session in the list. Right-click for its actions, as the Mac's `SessionActions`:
/// Pin or Unpin, Rename…, Fork, Archive, and Delete… under a line.
class _SessionRow extends StatefulWidget {
  const _SessionRow({required this.app, required this.session});
  final AppState app;
  final SessionEntry session;
  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  final _menu = FlyoutController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  void _showMenu(Offset position) {
    final s = widget.session;
    final app = widget.app;
    // As the Mac's: everything but Pin waits for a connection.
    final canChange = app.connection.state == LinkState.connected;
    _menu.showFlyout(
      position: position,
      barrierColor: const Color(0x00000000),
      builder: (context) => MenuFlyout(items: [
        MenuFlyoutItem(
          leading: Icon(s.isPinned ? Glyphs.unpin : Glyphs.pin),
          text: Text(s.isPinned ? 'Unpin' : 'Pin'),
          onPressed: () => app.setPinned(s, !s.isPinned),
        ),
        MenuFlyoutItem(
            leading: const Icon(Glyphs.rename),
            text: const Text('Rename…'),
            onPressed: canChange ? () => _afterMenu(_rename) : null),
        MenuFlyoutItem(
          leading: const Icon(Glyphs.branch),
          text: const Text('Fork'),
          onPressed: canChange ? () => app.forkSession(s) : null,
        ),
        MenuFlyoutItem(
          leading: const Icon(Glyphs.archive),
          text: const Text('Archive'),
          onPressed: canChange ? () => app.archiveSession(s) : null,
        ),
        const MenuFlyoutSeparator(),
        // Destructive, in red: WinUI's `SystemFillColorCritical`. (A menu is in the
        // overlay, outside the window's PaletteScope.)
        MenuFlyoutItemBuilder(builder: (context) {
          final red = FluentTheme.of(context).brightness == Brightness.dark
              ? const Color(0xFFFF99A4)
              : const Color(0xFFC42B1C);
          return MenuFlyoutItem(
            leading: Icon(Glyphs.delete, color: red),
            text: Text('Delete…', style: TextStyle(color: red)),
            onPressed: canChange ? () => _afterMenu(_delete) : null,
          ).build(context);
        }),
      ]),
    );
  }

  /// Runs [action] once the menu has closed: a menu item pops its menu after it is
  /// pressed, and a dialog opened before that would be taken down with it.
  void _afterMenu(Future<void> Function() action) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });

  String get _title => (widget.session.title?.isNotEmpty ?? false) ? widget.session.title! : 'Untitled chat';

  /// Rename Chat, in a dialog with the title to edit; Enter renames.
  Future<void> _rename() async {
    final controller = TextEditingController(text: widget.session.title ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Rename Chat'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextBox(
            controller: controller,
            autofocus: true,
            placeholder: 'Title',
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ]),
        actions: [
          Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context)),
          FilledButton(child: const Text('Rename'), onPressed: () => Navigator.pop(context, controller.text)),
        ],
      ),
    );
    controller.dispose();
    if (title != null && title.trim().isNotEmpty) await widget.app.renameSession(widget.session, title);
  }

  /// Delete…, confirmed first: its messages are deleted from Hermes for good.
  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Delete \u201c$_title\u201d?'),
        content: const Text('Its messages are deleted from Hermes for good.'),
        actions: [
          Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context, false)),
          FilledButton(
            style: ButtonStyle(backgroundColor: WidgetStatePropertyAll(Colors.red)),
            child: const Text('Delete'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) await widget.app.deleteSession(widget.session);
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final app = widget.app;
    final s = widget.session;
    return FlyoutTarget(
      controller: _menu,
      child: GestureDetector(
        onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
        child: Padding(
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
                      ? Container(width: 8, height: 8, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle))
                      : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// A section's title. The list's own sections (Bot Chat, Pinned, Sessions) larger and
/// bold, in the text colour (the user, 2026-11-18); a date group's ("Yesterday") small.
/// The sidebar's two tabs, Chats and Cron Jobs, as the Mac's `SessionListTabBar`:
/// small pills of the window's own style, the picked one on the accent.
class _SessionTabs extends StatelessWidget {
  const _SessionTabs({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final alerts = app.cron.jobs.where((j) => j.needsAttention).length;
    Widget tab(String label, IconData icon, bool picked, VoidCallback? onPressed) => Tooltip(
          message: label,
          child: HoverButton(
            onPressed: onPressed,
            builder: (context, states) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: picked ? p.accent : states.isHovered ? p.subtle : const Color(0x00000000),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 13, color: picked ? Colors.white : p.text2),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 12, color: picked ? Colors.white : p.text2)),
              ]),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(children: [
        tab('Chats', Glyphs.chat, !app.isCronShown, () => app.showCron(false)),
        const SizedBox(width: 4),
        Stack(children: [
          tab('Cron Jobs', Glyphs.clock, app.isCronShown, () => app.showCron(true)),
          if (alerts > 0)
            Positioned(
              right: 0,
              top: 0,
              child: Container(width: 7, height: 7, decoration: BoxDecoration(color: p.critical, shape: BoxShape.circle)),
            ),
        ]),
      ]),
    );
  }
}

/// The search field, always present so Ctrl+F finds it, as the Mac's toolbar search.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.app, this.focus});
  final AppState app;
  final FocusNode? focus;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.app.searchText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Row(children: [
      Icon(Glyphs.search, size: 14, color: p.text3),
      const SizedBox(width: 8),
      Expanded(
        child: SizedBox(
          height: 30,
          child: TextBox(
            controller: _controller,
            focusNode: widget.focus,
            placeholder: 'Search chats',
            placeholderStyle: TextStyle(fontSize: 12, color: p.text3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            style: TextStyle(fontSize: 12, color: p.text),
            onSubmitted: null,
            onChanged: (value) {
              widget.app.setSearchText(value);
              setState(() {});
            },
          ),
        ),
      ),
    ]);
  }
}

/// The search's results, in the sessions list's place (the Mac's
/// `SessionSearchResultsList`): the best match first, each row opening its chat.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final app = this.app;
    final search = app.search;
    final query = app.searchText.trim();
    return ListView(padding: EdgeInsets.zero, children: [
      if (!search.isAvailable)
        _SearchNotice(icon: Glyphs.search, title: 'Search Unavailable',
            detail: "This server's sign-in can't read the dashboard.")
      else if (search.error case final error? when search.query == query)
        _SearchNotice(
            icon: Glyphs.error, title: 'Search Failed', detail: error,
            action: 'Try Again', onAction: () => app.setSearchText(app.searchText))
      else if (search.results.isNotEmpty) ...[
        _Header(search.results.length == 1 ? '1 chat' : '${search.results.length} chats', major: true),
        for (final result in search.results) _SearchRow(app: app, result: result),
      ]
      else if (search.isSearching || search.query != query)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: ProgressRing()))
      else
        _SearchNotice(
            icon: Glyphs.search,
            title: query.isEmpty ? 'Search Chats' : 'No Results for "$query"',
            detail: query.isEmpty
                ? 'Find a chat by what was said in it, its title or its id.'
                : "Try different words, or the chat's title."),
    ]);
  }
}

/// Where the results' empty states show, as the Mac's `ContentUnavailableView`.
class _SearchNotice extends StatelessWidget {
  const _SearchNotice({required this.icon, required this.title, required this.detail, this.action, this.onAction});
  final IconData icon;
  final String title;
  final String detail;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 22, color: p.text3),
        const SizedBox(height: 8),
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text)),
        const SizedBox(height: 4),
        Text(detail, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: p.text2, height: 1.3)),
        if (action case final label?)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Button(onPressed: onAction, child: Text(label)),
          ),
      ]),
    );
  }
}

/// A search hit: the chat's title, the matched text with the query's words in bold,
/// and when the chat was last active (the Mac's `SessionSearchRow`).
class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.app, required this.result});
  final AppState app;
  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final selected = app.selectedRow == result.id;
    return ListItem(
      selected: selected,
      height: 56,
      onPressed: () => app.openSearchResult(result),
      child: _TwoLines(
        title: result.title,
        bold: selected,
        subtitle: null,
        trailing: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final segment in result.segments.take(2))
            Text(
              segment.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: segment.isMatch ? p.text : p.text2,
                fontWeight: segment.isMatch ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          if (result.date case final date?)
            Text(relativeTime(date), style: TextStyle(fontSize: 11, color: p.text3)),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.major = false});
  final String text;
  final bool major;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, major ? 14 : 10, 8, major ? 6 : 4),
      child: Text(text,
          style: major
              ? TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.text)
              : TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.text2)),
    );
  }
}

class _TwoLines extends StatelessWidget {
  const _TwoLines({required this.title, this.subtitle, this.bold = false, this.trailing});
  final String title;
  final String? subtitle;
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
          if ((subtitle ?? '').isNotEmpty)
            Text(subtitle!,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.text2, height: 1.3)),
        ]),
      ),
      ?trailing,
      const SizedBox(width: 10),
    ]);
  }
}

