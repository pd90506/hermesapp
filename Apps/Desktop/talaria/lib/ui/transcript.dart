import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'markdown.dart';
import 'theme.dart';

/// The transcript as the Mac lays it out (`TranscriptMessages`, `MessageRowContent.swift`):
/// HermesKit's blocks, each a message or a turn's work under its "Completed in" line,
/// then the waiting row while a reply is awaited, and the turn's status line. Newest at
/// the bottom; it follows the end while a reply streams.
class Transcript extends StatefulWidget {
  const Transcript({super.key, required this.chat, required this.app, required this.contentWidth});
  final ChatSnapshot chat;
  final AppState app;
  final double contentWidth;

  @override
  State<Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<Transcript> {
  /// What the user opened or closed, by fold, for this chat: a row scrolled away and
  /// back keeps it, as the Mac's `@Remembered`.
  final _folds = <String, bool>{};

  @override
  void didUpdateWidget(Transcript old) {
    super.didUpdateWidget(old);
    if (old.chat.sessionID != widget.chat.sessionID) _folds.clear();
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final items = {for (final i in chat.items) i.id: i};
    final rows = <Widget>[];
    for (final block in chat.blocks) {
      switch (block) {
        case ItemBlock(:final item):
          final it = items[item];
          if (it == null || it.isBlank) continue;
          rows.add(MessageRow(item: it, chat: chat, app: widget.app));
        case WorkBlock(:final work):
          rows.add(_TurnWorkView(id: block.id, work: work, items: items, chat: chat, app: widget.app));
      }
    }
    if (chat.waiting case final waiting?) rows.add(_WaitingRow(waiting: waiting));
    if (chat.waiting == null && chat.isRunning && chat.status != null) {
      rows.add(Builder(builder: (context) {
        final p = PaletteScope.of(context);
        return Row(children: [
          Icon(Glyphs.more, size: 12, color: p.text2),
          const SizedBox(width: 6),
          Expanded(child: Text(chat.status!, style: TextStyle(fontSize: 12, color: p.text2))),
        ]);
      }));
    }
    return _Folds(
      folds: _folds,
      onChanged: () => setState(() {}),
      child: _TranscriptItems(items: items, child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        itemCount: rows.length,
        itemBuilder: (context, index) => Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.contentWidth),
            child: Padding(padding: const EdgeInsets.only(top: 14), child: rows[rows.length - 1 - index]),
          ),
        ),
      )),
    );
  }
}

/// The transcript's remembered folds, for the rows under it.
class _Folds extends InheritedWidget {
  const _Folds({required this.folds, required this.onChanged, required super.child});
  final Map<String, bool> folds;
  final VoidCallback onChanged;

  static _Folds of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Folds>()!;

  bool? operator [](String key) => folds[key];
  void set(String key, bool open) {
    folds[key] = open;
    onChanged();
  }

  @override
  bool updateShouldNotify(_Folds old) => true;
}

// MARK: - Messages

/// A message: a prompt (its bubble, and the action bar under it), a reply (reasoning,
/// Markdown, action bar), a tool call, a background notice or a review note. Right-click
/// for Copy Message and Copy Conversation, as on the Mac.
class MessageRow extends StatefulWidget {
  const MessageRow({super.key, required this.item, required this.chat, required this.app, this.isInTurnWork = false});
  final ChatItem item;
  final ChatSnapshot chat;
  final AppState app;

  /// Inside a turn's opened work: no action bar under its paragraphs (as the Mac's).
  final bool isInTurnWork;

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> {
  bool _hovering = false;
  bool _secondaryDown = false;
  final _menu = FlyoutController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  ChatItem get item => widget.item;

  Future<void> _copyMessage() async {
    final text = await widget.app.messageSource(item.id) ?? item.text;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _copyConversation() async {
    final text = await widget.app.conversationSource();
    if (text != null) await Clipboard.setData(ClipboardData(text: text));
  }

  void _showMenu(Offset position) {
    _menu.showFlyout(
      position: position,
      barrierColor: const Color(0x00000000),
      builder: (context) => MenuFlyout(items: [
        MenuFlyoutItem(leading: const Icon(Glyphs.copy), text: const Text('Copy Message'), onPressed: _copyMessage),
        MenuFlyoutItem(text: const Text('Copy Conversation'), onPressed: _copyConversation),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = _row(context);
    if (row == null) return const SizedBox.shrink();
    // A Listener, not a gesture: the reply's selectable text takes the right button's
    // gestures for itself.
    return FlyoutTarget(
      controller: _menu,
      child: Listener(
        onPointerDown: (e) => _secondaryDown = e.buttons == kSecondaryMouseButton,
        onPointerUp: (e) {
          if (_secondaryDown) _showMenu(e.position);
          _secondaryDown = false;
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: row,
        ),
      ),
    );
  }

  Widget? _row(BuildContext context) {
    final p = PaletteScope.of(context);
    final isNewest = widget.chat.newestMessageID == item.id;
    if (item.notice case final notice?) return _BackgroundNoticeRow(id: item.id, notice: notice);
    if (item.review case final note?) return _ReviewNoteRow(id: item.id, note: note);
    switch (item.role) {
      case Role.user:
        final sent = item.images.isNotEmpty || item.attachments.isNotEmpty;
        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(left: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                // What was sent with the prompt, above its bubble, as on the Mac.
                if (sent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: [
                      for (final image in item.images) _SentImageView(image: image, app: widget.app),
                      for (final name in item.attachments) _FileChip(icon: Glyphs.document, name: name),
                    ]),
                  ),
                if (item.text.isNotEmpty || !sent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(color: p.userBubble, borderRadius: BorderRadius.circular(8)),
                    child: SelectableText(item.text, style: TextStyle(fontSize: 14, color: p.text, height: 1.45)),
                  ),
                MessageActionBar(
                  isHovering: _hovering,
                  isNewest: isNewest,
                  trailing: true,
                  timestamp: item.timestamp,
                  outgoingStatus: item.outgoingStatus,
                  copy: _copyMessage,
                ),
              ]),
            ),
          ),
        );
      case Role.assistant:
        if (item.isBlank) return null;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((item.reasoning ?? '').isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: _ReasoningFold(item: item)),
          if (item.markdown.isNotEmpty)
            _Selectable(child: MarkdownBody(parts: item.markdown))
          else if (item.text.trim().isNotEmpty)
            SelectableText(item.text.trim(), style: TextStyle(fontSize: 14, color: p.text, height: 1.55)),
          if (item.outcome == 'interrupted')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Interrupted', style: TextStyle(fontSize: 12, color: p.text2)),
            ),
          // Directly under the message, so moving down onto it never leaves the row.
          if (item.hasActionBar && !widget.isInTurnWork)
            MessageActionBar(
              isHovering: _hovering,
              isNewest: isNewest,
              timestamp: item.timestamp,
              branch: widget.chat.canBranch ? () => widget.app.branch(item.id) : null,
              copy: _copyMessage,
            ),
        ]);
      case Role.tool:
        final tool = item.tool;
        if (tool == null) return null;
        return _ToolMessage(id: item.id, tool: tool);
      case Role.system:
        if (item.isCompressionNote) {
          return Center(
            child: Text(item.text, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: p.text2)),
          );
        }
        return Text(item.text, style: TextStyle(fontSize: 12, color: p.text2));
    }
  }
}

/// The row under a message, after ChatGPT's and Desktop's, as the Mac's: a small grey
/// Copy, a "…" menu (Branch in New Chat, on replies) and when it was written. Shown
/// while the pointer is over the message, always on the newest, and while a prompt is
/// sending; kept in the layout while hidden, so nothing moves.
class MessageActionBar extends StatelessWidget {
  const MessageActionBar({
    super.key,
    required this.isHovering,
    required this.isNewest,
    required this.copy,
    this.trailing = false,
    this.timestamp,
    this.outgoingStatus,
    this.branch,
  });
  final bool isHovering, isNewest, trailing;
  final DateTime? timestamp;

  /// Replaces the time in its slot (Sending…, Queued, a failure).
  final String? outgoingStatus;
  final VoidCallback? branch;
  final VoidCallback copy;

  bool get isVisible => outgoingStatus != null || isHovering || isNewest;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    // Lighter than secondary text, so the row stays quiet under the message.
    final ink = p.text.withValues(alpha: 0.42);
    final status = outgoingStatus;
    final children = <Widget>[
      _BarButton(icon: Glyphs.copy, tooltip: 'Copy Message', color: ink, onPressed: copy),
      if (branch case final branch?) _MoreMenu(ink: ink, branch: branch),
      if (status != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Tooltip(
            message: status,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(status,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ink)),
            ),
          ),
        )
      else if (timestamp case final t?)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Tooltip(
            message: fullDate(t),
            child: Text(messageTime(t),
                style: TextStyle(fontSize: 11, color: ink, fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
    ];
    return IgnorePointer(
      ignoring: !isVisible,
      child: AnimatedOpacity(
        opacity: isVisible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: SizedBox(
          height: 26,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: trailing ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  /// "3:27 PM" today, "Yesterday, 3:27 PM", else "Sep 28, 3:27 PM" (`MessageTimestamp`).
  static String messageTime(DateTime t, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final clock = '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
    final today = DateTime(reference.year, reference.month, reference.day);
    final day = DateTime(t.year, t.month, t.day);
    if (day == today) return clock;
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday, $clock';
    return '${_months[t.month - 1]} ${t.day}, $clock';
  }

  static String fullDate(DateTime t) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${days[t.weekday - 1]}, ${months[t.month - 1]} ${t.day}, ${t.year} at ${messageTime(t, now: t)}';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.tooltip, required this.color, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Tooltip(
      message: tooltip,
      child: HoverButton(
        onPressed: onPressed,
        cursor: SystemMouseCursors.basic,
        builder: (context, states) => Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: states.isHovered ? p.subtle : const Color(0x00000000),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 12, color: color),
        ),
      ),
    );
  }
}

/// The action bar's "…": Branch in New Chat.
class _MoreMenu extends StatefulWidget {
  const _MoreMenu({required this.ink, required this.branch});
  final Color ink;
  final VoidCallback branch;
  @override
  State<_MoreMenu> createState() => _MoreMenuState();
}

class _MoreMenuState extends State<_MoreMenu> {
  final _menu = FlyoutController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FlyoutTarget(
        controller: _menu,
        child: _BarButton(
          icon: Glyphs.more,
          tooltip: 'More',
          color: widget.ink,
          onPressed: () => _menu.showFlyout(
            barrierColor: const Color(0x00000000),
            placementMode: FlyoutPlacementMode.bottomLeft,
            builder: (context) => MenuFlyout(items: [
              MenuFlyoutItem(
                  leading: const Icon(Glyphs.branch), text: const Text('Branch in New Chat'), onPressed: widget.branch),
            ]),
          ),
        ),
      );
}

/// Text that can be selected across a message's paragraphs, code and tables, and copied
/// with Ctrl+C.
class _Selectable extends StatelessWidget {
  const _Selectable({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SelectionArea(
        selectionControls: WindowsTextSelectionHandleControls(),
        contextMenuBuilder: null,
        child: child,
      );
}

// MARK: - Folds

enum _Chevron {
  /// Points right, turning down while open.
  disclosure,

  /// Points down, and up while open: a turn's "Completed in" line.
  upDown,

  /// A disclosure chevron shown only while the pointer is over the line.
  onHover,
  none,
}

/// The line every fold in the chat opens with (reasoning, a tool call, a turn's work, a
/// group of its steps, a step): its label, then a chevron. The whole line is the button,
/// with the hand pointer, as the Mac's `FoldButton`.
class _FoldButton extends StatefulWidget {
  const _FoldButton({required this.open, required this.onChanged, required this.label, this.chevron = _Chevron.disclosure});
  final bool open;
  final ValueChanged<bool>? onChanged;
  final List<Widget> label;
  final _Chevron chevron;
  @override
  State<_FoldButton> createState() => _FoldButtonState();
}

class _FoldButtonState extends State<_FoldButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final enabled = widget.onChanged != null;
    Widget? chevron;
    switch (widget.chevron) {
      case _Chevron.disclosure:
      case _Chevron.onHover:
        chevron = Opacity(
          opacity: widget.chevron == _Chevron.onHover && !_hovering ? 0 : 1,
          child: AnimatedRotation(
            turns: widget.open ? 0.25 : 0,
            duration: const Duration(milliseconds: 200),
            child: Icon(Glyphs.chevronRight, size: 9, color: p.text3),
          ),
        );
      case _Chevron.upDown:
        chevron = Icon(widget.open ? Glyphs.chevronUp : Glyphs.chevronDown, size: 9, color: p.text3);
      case _Chevron.none:
        chevron = null;
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => widget.onChanged!(!widget.open) : null,
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 13, color: p.text2, height: 1.35),
          child: IconTheme.merge(
            data: IconThemeData(size: 12, color: p.text3),
            child: Row(children: [
              ...widget.label,
              if (chevron != null) ...[const SizedBox(width: 6), chevron],
              const Spacer(),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A fold's open state: the user's choice once made, else [initial].
bool _isOpen(BuildContext context, String key, bool initial) => _Folds.of(context)[key] ?? initial;

/// A reply's reasoning, closed under a "Reasoning" line, opening below it.
class _ReasoningFold extends StatelessWidget {
  const _ReasoningFold({required this.item});
  final ChatItem item;
  @override
  Widget build(BuildContext context) {
    final key = 'reasoning:${item.id}';
    final open = _isOpen(context, key, false);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _FoldButton(
        open: open,
        onChanged: (v) => _Folds.of(context).set(key, v),
        label: const [Text('Reasoning')],
      ),
      if (open) Padding(padding: const EdgeInsets.only(top: 6), child: _ReasoningText(item: item)),
    ]);
  }
}

/// Reasoning as it reads once shown: smaller than the reply, in the secondary colour.
class _ReasoningText extends StatelessWidget {
  const _ReasoningText({required this.item});
  final ChatItem item;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return item.reasoningMarkdown.isNotEmpty
        ? _Selectable(child: MarkdownBody(parts: item.reasoningMarkdown, secondary: true))
        : SelectableText((item.reasoning ?? '').trim(), style: TextStyle(fontSize: 13, color: p.text2, height: 1.5));
  }
}

// MARK: - A turn's work

/// "Working… 12s" while the turn works, "Completed in 45s" once done, with a thin rule
/// under it; opened, the turn's commentary and its groups of steps. Open while the turn
/// works, closed once it is done, until the user opens or closes it (the Mac's
/// `TurnWorkView`).
class _TurnWorkView extends StatefulWidget {
  const _TurnWorkView({required this.id, required this.work, required this.items, required this.chat, required this.app});
  final String id;
  final TurnWork work;
  final Map<String, ChatItem> items;
  final ChatSnapshot chat;
  final AppState app;
  @override
  State<_TurnWorkView> createState() => _TurnWorkViewState();
}

class _TurnWorkViewState extends State<_TurnWorkView> {
  /// For a turn this chat did not send: count from when the line appeared.
  final _appeared = DateTime.now();

  /// When this view saw the work end, for a turn whose rows carry no time yet.
  DateTime? _settledAt;

  @override
  void didUpdateWidget(_TurnWorkView old) {
    super.didUpdateWidget(old);
    if (old.work.isLive != widget.work.isLive) _settledAt = widget.work.isLive ? null : DateTime.now();
  }

  String get _settledTitle {
    final work = widget.work;
    if (work.duration != null) return work.title;
    final start = work.startedAt, end = _settledAt;
    if (start == null || end == null || end.isBefore(start)) return work.title;
    return '${work.interrupted ? 'Stopped after' : 'Completed in'} ${elapsedText(end.difference(start))}';
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final work = widget.work;
    final key = 'work:${widget.id}';
    final open = _isOpen(context, key, work.isLive);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _FoldButton(
        open: open,
        chevron: _Chevron.upDown,
        onChanged: (v) => _Folds.of(context).set(key, v),
        label: [
          if (work.isLive)
            _Ticking(builder: (now) => Text('Working… ${elapsedText(now.difference(work.startedAt ?? _appeared))}'))
          else
            Text(_settledTitle),
        ],
      ),
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Container(height: 1, color: p.divider)),
      if (open)
        for (final (i, entry) in work.entries.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: switch (entry) {
              // Remembered by place in the turn as well as by id: a model that numbers its
              // calls afresh each round gives two groups the same id.
              WorkEntry(:final group?) => _StepGroupView(group: group, foldKey: '$key/$i'),
              WorkEntry(:final item?) when widget.items[item] != null =>
                MessageRow(item: widget.items[item]!, chat: widget.chat, app: widget.app, isInTurnWork: true),
              _ => const SizedBox.shrink(),
            },
          ),
    ]);
  }
}

/// Elapsed time as the Mac shows it (`Transcript.Waiting.elapsedText`): `4s`, `1m 05s`,
/// `1h 02m`.
String elapsedText(Duration d) {
  String two(int v) => v < 10 ? '0$v' : '$v';
  final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ${two(seconds % 60)}s';
  return '${minutes ~/ 60}h ${two(minutes % 60)}m';
}

/// Rebuilds every second, with the time.
class _Ticking extends StatefulWidget {
  const _Ticking({required this.builder});
  final Widget Function(DateTime now) builder;
  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(DateTime.now());
}

/// A group of a turn's steps: its kind's icon and what its calls did ("Ran commands"),
/// a chevron only under the pointer; while the turn works in it, its newest step's line.
/// Opened, its steps one line each.
class _StepGroupView extends StatelessWidget {
  const _StepGroupView({required this.group, required this.foldKey});
  final StepGroup group;
  final String foldKey;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final key = '$foldKey:${group.id}';
    final open = _isOpen(context, key, false);
    final live = group.isLive && group.steps.isNotEmpty ? group.steps.last : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Tooltip(
        message: group.summary,
        child: _FoldButton(
          open: open,
          chevron: _Chevron.onHover,
          onChanged: (v) => _Folds.of(context).set(key, v),
          label: live != null
              ? _stepLine(context, live)
              : [
                  SizedBox(
                      width: 14,
                      child: Icon(group.iconTool == null ? Glyphs.think : toolIcon(group.iconTool!),
                          size: 12, color: p.text3)),
                  const SizedBox(width: 6),
                  Flexible(child: Text(group.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
        ),
      ),
      if (open)
        Padding(
          padding: const EdgeInsets.only(left: 20, top: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, step) in group.steps.indexed)
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _WorkStepView(step: step, foldKey: '$key/$i')),
          ]),
        ),
    ]);
  }
}

/// One step: "Bash · git status", opening in place to its card.
class _WorkStepView extends StatelessWidget {
  const _WorkStepView({required this.step, required this.foldKey});
  final WorkStep step;
  final String foldKey;
  @override
  Widget build(BuildContext context) {
    final key = '$foldKey:${step.id}';
    final open = _isOpen(context, key, false);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _FoldButton(
        open: open,
        chevron: _Chevron.onHover,
        onChanged: (v) => _Folds.of(context).set(key, v),
        label: _stepLine(context, step),
      ),
      if (open) Padding(padding: const EdgeInsets.only(top: 4), child: _WorkStepCard(step: step)),
    ]);
  }
}

/// A step's line: its icon (or its status while it runs or once it failed), its kind,
/// a dot, and what it was about, cut short at the end.
List<Widget> _stepLine(BuildContext context, WorkStep step) {
  final p = PaletteScope.of(context);
  final Widget glyph;
  if (step.isLive) {
    glyph = const SizedBox(width: 11, height: 11, child: ProgressRing(strokeWidth: 1.5));
  } else if (step.failed) {
    glyph = Icon(Glyphs.error, size: 12, color: p.critical);
  } else {
    glyph = Icon(step.toolName == null ? Glyphs.think : toolIcon(step.toolName!), size: 12, color: p.text3);
  }
  return [
    SizedBox(width: 14, child: Center(child: glyph)),
    const SizedBox(width: 6),
    Text(step.label, style: TextStyle(color: step.failed ? p.critical : p.text2)),
    if (step.summary.isNotEmpty) ...[
      const SizedBox(width: 6),
      Text('·', style: TextStyle(color: p.text3)),
      const SizedBox(width: 6),
      Flexible(
        child: Text(step.summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text3)),
      ),
    ],
  ];
}

/// An opened step: a rounded card whose top holds a status dot, the working folder (or
/// the call's title), the whole command and a Copy button; under a rule, the output,
/// scrolling past a few lines. Reasoning shows in full.
class _WorkStepCard extends StatelessWidget {
  const _WorkStepCard({required this.step});
  final WorkStep step;

  static const outputMaxLines = 12;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final transcript = context.findAncestorWidgetOfExactType<_TranscriptItems>();
    final item = transcript?.items[step.item];
    final tool = item?.tool;
    final children = <Widget>[];
    if (step.isThink) {
      children
        ..add(_header(context, Text('Reasoning', style: TextStyle(fontSize: 12, color: p.text3))))
        ..add(Container(height: 1, color: p.divider));
      if (item != null) children.add(Padding(padding: const EdgeInsets.all(8), child: _ReasoningText(item: item)));
    } else if (tool != null) {
      children.add(_header(context, _toolHeading(context, tool)));
      if (tool.hasBody) {
        children
          ..add(Container(height: 1, color: p.divider))
          ..add(Padding(
            padding: const EdgeInsets.all(8),
            child: _ToolCallBody(tool: tool, showsCommand: false, showsAllOutput: true, outputMaxLines: outputMaxLines),
          ));
      }
    } else {
      children.add(_header(context, Text(step.label, style: TextStyle(fontSize: 12, color: p.text2))));
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.cardStroke),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _header(BuildContext context, Widget heading) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 4), child: _StepStatusDot(step: step, tool: _tool(context))),
        const SizedBox(width: 8),
        Expanded(child: heading),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Copy',
          child: HoverButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: step.copyText)),
            builder: (context, states) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: states.isHovered ? p.subtle : const Color(0x00000000),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Glyphs.copy, size: 11, color: p.text2),
                const SizedBox(width: 4),
                Text('Copy', style: TextStyle(fontSize: 12, color: p.text2)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  ToolCall? _tool(BuildContext context) =>
      context.findAncestorWidgetOfExactType<_TranscriptItems>()?.items[step.item]?.tool;

  Widget _toolHeading(BuildContext context, ToolCall tool) {
    final p = PaletteScope.of(context);
    final caption = TextStyle(fontSize: 12, color: p.text3);
    if (tool.terminalCommand case final command?) {
      final folder = _folderName(step.workdir);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, children: [
          if (folder != null) Text(folder, style: caption),
          if (tool.terminalExitCode case final code? when code != 0)
            Text('exit $code', style: TextStyle(fontFamily: monoFont, fontSize: 11, color: p.caution)),
          if (!tool.isPending && tool.durationLabel != null) Text(tool.durationLabel!, style: caption),
        ]),
        const SizedBox(height: 3),
        SelectableText(command.isEmpty ? step.summary : command,
            style: TextStyle(fontFamily: monoFont, fontSize: 12, color: p.text2)),
      ]);
    }
    return Wrap(spacing: 6, children: [
      Text(tool.title, style: TextStyle(fontSize: 12, color: p.text2)),
      if (!tool.isPending && tool.countLabel != null) Text(tool.countLabel!, style: caption),
      if (!tool.isPending && tool.durationLabel != null) Text(tool.durationLabel!, style: caption),
    ]);
  }

  static String? _folderName(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final parts = trimmed.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? trimmed : parts.last;
  }
}

/// A step's status in its card: running, done, failed or a warning.
class _StepStatusDot extends StatelessWidget {
  const _StepStatusDot({required this.step, this.tool});
  final WorkStep step;
  final ToolCall? tool;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    if (step.isLive) return const SizedBox(width: 10, height: 10, child: ProgressRing(strokeWidth: 1.5));
    final color = switch (tool?.status) {
      null => p.text2,
      ToolStatus.error => p.critical,
      ToolStatus.warning => p.caution,
      ToolStatus.notice => p.text2,
      ToolStatus.running || ToolStatus.success => p.success,
    };
    return Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

/// The transcript's items, for a step's card to find its item by id.
class _TranscriptItems extends InheritedWidget {
  const _TranscriptItems({required this.items, required super.child});
  final Map<String, ChatItem> items;
  @override
  bool updateShouldNotify(_TranscriptItems old) => !identical(items, old.items);
}

// MARK: - Tool calls

/// Desktop's tool icons (`TOOL_META`), as the Mac maps them to SF Symbols, in Segoe
/// Fluent Icons.
IconData toolIcon(String name) => switch (name) {
      'read_file' => Glyphs.page,
      'list_files' => Glyphs.folder,
      'search_files' || 'web_search' || 'session_search_recall' => Glyphs.search,
      'terminal' || 'execute_code' => Glyphs.terminal,
      'edit_file' || 'patch' || 'write_file' => Glyphs.editPage,
      'browser_take_screenshot' || 'image_generate' => Glyphs.photo,
      'clarify' => Glyphs.help,
      'cronjob' => Glyphs.clock,
      'memory' => Glyphs.memory,
      'todo' => Glyphs.list,
      'vision_analyze' => Glyphs.view,
      _ => name.startsWith('browser_') || name.startsWith('web_') ? Glyphs.globe : Glyphs.tool,
    };

/// One tool call outside a turn's work: its line (status or tool glyph, what it did,
/// counts and duration, chevron), opening in place into a bordered card.
class _ToolMessage extends StatelessWidget {
  const _ToolMessage({required this.id, required this.tool});
  final String id;
  final ToolCall tool;
  @override
  Widget build(BuildContext context) {
    if (tool.isHidden) return const SizedBox.shrink();
    final p = PaletteScope.of(context);
    final key = 'tool:$id';
    final open = _isOpen(context, key, tool.opensByDefault) && tool.isExpandable;
    final line = Padding(
      padding: open ? const EdgeInsets.symmetric(horizontal: 8, vertical: 5) : EdgeInsets.zero,
      child: _FoldButton(
        open: open,
        chevron: tool.isExpandable ? _Chevron.disclosure : _Chevron.none,
        onChanged: tool.isExpandable ? (v) => _Folds.of(context).set(key, v) : null,
        label: _toolLine(context, tool),
      ),
    );
    if (!open) return line;
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), border: Border.all(color: p.cardStroke)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        line,
        Container(height: 1, color: p.divider),
        Padding(padding: const EdgeInsets.all(6), child: _ToolCallBody(tool: tool)),
      ]),
    );
  }
}

/// A tool call's line: its glyph, title, result count, diff counts and duration.
List<Widget> _toolLine(BuildContext context, ToolCall tool) {
  final p = PaletteScope.of(context);
  final Widget glyph;
  if (tool.isPending) {
    glyph = const SizedBox(width: 11, height: 11, child: ProgressRing(strokeWidth: 1.5));
  } else if (tool.status == ToolStatus.error) {
    glyph = Icon(Glyphs.error, size: 12, color: p.critical);
  } else if (tool.status == ToolStatus.warning) {
    glyph = Icon(Glyphs.error, size: 12, color: p.caution);
  } else {
    glyph = Icon(toolIcon(tool.toolName), size: 12, color: p.text3);
  }
  final titleColor = tool.isPending
      ? p.text3
      : switch (tool.status) {
          ToolStatus.error => p.critical,
          ToolStatus.warning => p.caution,
          _ => p.text2,
        };
  const digits = [FontFeature.tabularFigures()];
  return [
    SizedBox(width: 14, child: Center(child: glyph)),
    const SizedBox(width: 6),
    Flexible(child: Text(tool.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: titleColor))),
    if (!tool.isPending && tool.countLabel != null) ...[
      const SizedBox(width: 6),
      Text(tool.countLabel!, style: TextStyle(color: p.text3)),
    ],
    if (tool.isFileEdit && !tool.isPending && tool.inlineDiff.isNotEmpty) ...[
      if (tool.added > 0) ...[
        const SizedBox(width: 6),
        Text('+${tool.added}', style: TextStyle(color: p.success, fontFeatures: digits)),
      ],
      if (tool.removed > 0) ...[
        const SizedBox(width: 6),
        Text('−${tool.removed}', style: TextStyle(color: p.critical, fontFeatures: digits)),
      ],
    ],
    if (!tool.isFileEdit && !tool.isPending && tool.durationLabel != null) ...[
      const SizedBox(width: 6),
      Text(tool.durationLabel!, style: TextStyle(color: p.text3, fontFeatures: digits)),
    ],
  ];
}

/// What an opened tool call shows, in Desktop's order: the `$` command, search hits,
/// the diff, then the detail (an error, a command's streams, or the output).
class _ToolCallBody extends StatelessWidget {
  const _ToolCallBody({required this.tool, this.showsCommand = true, this.showsAllOutput = false, this.outputMaxLines});
  final ToolCall tool;
  final bool showsCommand, showsAllOutput;
  final int? outputMaxLines;

  @override
  Widget build(BuildContext context) {
    final command = tool.terminalCommand;
    final children = <Widget>[
      if (showsCommand && command != null && (command.isNotEmpty || tool.terminalExitCode != null))
        _TerminalCommandLine(command: command, exitCode: tool.terminalExitCode),
      if (tool.searchHits.isNotEmpty) _SearchHitList(query: tool.searchQuery, hits: tool.searchHits),
      if (tool.inlineDiff.isNotEmpty) _ToolTextBox(text: tool.inlineDiff, kind: _TextKind.diff),
      if (tool.showsDetail || (showsAllOutput && tool.inlineDiff.isEmpty && tool.detail.isNotEmpty)) _detail(context),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 6), child],
    ]);
  }

  Widget _detail(BuildContext context) {
    final p = PaletteScope.of(context);
    if (tool.status == ToolStatus.error) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (tool.errorSummary.isNotEmpty)
          SelectableText(tool.errorSummary,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.critical)),
        if (tool.detailBody.isNotEmpty) ...[
          const SizedBox(height: 4),
          _ToolTextBox(text: tool.detailBody, kind: _TextKind.code, maxLines: _ToolTextBox.errorMaxLines),
        ],
      ]);
    }
    if (tool.stdout != null || tool.stderr != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _SectionLabel(tool.detailLabel),
        if (tool.stdout case final out?) ...[
          if (tool.stderr != null) const _SectionLabel('stdout'),
          _ToolTextBox(text: out, kind: _TextKind.code, maxLines: outputMaxLines),
        ],
        if (tool.stderr case final err?) ...[
          const _SectionLabel('stderr'),
          _ToolTextBox(text: err, kind: _TextKind.code, maxLines: outputMaxLines, muted: true),
        ],
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SectionLabel(tool.detailLabel),
      _ToolTextBox(
          text: tool.detail, kind: tool.rendersDetailAsCode ? _TextKind.code : _TextKind.text, maxLines: outputMaxLines),
    ]);
  }
}

/// A small heading over a section of an opened call ("STDOUT", "ERROR DETAILS").
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 0.6, color: PaletteScope.of(context).text3)),
    );
  }
}

/// `$ command` and its exit code, above a terminal call's output.
class _TerminalCommandLine extends StatelessWidget {
  const _TerminalCommandLine({required this.command, this.exitCode});
  final String command;
  final int? exitCode;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: p.subtle,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: p.cardStroke),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (command.isNotEmpty)
          Expanded(
            child: SelectableText.rich(TextSpan(
              style: TextStyle(fontFamily: monoFont, fontSize: 12, color: p.text2),
              children: [TextSpan(text: '\$ ', style: TextStyle(color: p.accent)), TextSpan(text: command)],
            )),
          )
        else
          const Spacer(),
        if (exitCode case final code?)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: p.subtle2, borderRadius: BorderRadius.circular(3)),
            child: Text('exit $code',
                style: TextStyle(fontFamily: monoFont, fontSize: 11, color: code == 0 ? p.success : p.caution)),
          ),
      ]),
    );
  }
}

/// A web search's hits: the query, then each hit's title and snippet.
class _SearchHitList extends StatelessWidget {
  const _SearchHitList({this.query, required this.hits});
  final String? query;
  final List<SearchHit> hits;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (query case final q?)
        Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: p.text2), children: [
          TextSpan(text: 'Search ', style: TextStyle(color: p.text3)),
          TextSpan(text: q),
        ])),
      const SizedBox(height: 6),
      const _SectionLabel('Search results'),
      for (final hit in hits)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(hit.title.isEmpty ? hit.url : hit.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.accent)),
            if (hit.snippet.isNotEmpty)
              Text(hit.snippet, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: p.text3)),
          ]),
        ),
    ]);
  }
}

enum _TextKind { code, text, diff }

/// A block of a call's text: code or output in a monospaced font, a diff in its colours,
/// other details as text. Past its line limit it scrolls inside itself.
class _ToolTextBox extends StatelessWidget {
  const _ToolTextBox({required this.text, required this.kind, this.maxLines, this.muted = false});
  final String text;
  final _TextKind kind;
  final int? maxLines;
  final bool muted;

  static const outputMaxLines = 5;
  static const diffMaxLines = 12;
  static const errorMaxLines = 14;
  static const _lineHeight = 16.0;

  int get _limit => maxLines ?? (kind == _TextKind.diff ? diffMaxLines : outputMaxLines);

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final mono = TextStyle(fontFamily: monoFont, fontSize: 12, height: _lineHeight / 12);
    final Widget styled = switch (kind) {
      _TextKind.code => SelectableText(text, style: mono.copyWith(color: muted ? p.text3 : p.text2)),
      _TextKind.text => SelectableText(text, style: TextStyle(fontSize: 12, height: _lineHeight / 12, color: p.text2)),
      _TextKind.diff => SelectableText.rich(TextSpan(style: mono, children: [
          for (final (i, line) in text.split('\n').indexed)
            TextSpan(
              text: (i > 0 ? '\n' : '') + line,
              style: TextStyle(
                  color: line.startsWith('+') && !line.startsWith('+++')
                      ? p.success
                      : line.startsWith('-') && !line.startsWith('---')
                          ? p.critical
                          : p.text2),
            ),
        ])),
    };
    final content = Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: styled);
    final lines = '\n'.allMatches(text).length + 1;
    if (lines <= _limit) return content;
    return SizedBox(
      height: _lineHeight * _limit + 8,
      child: SingleChildScrollView(child: content),
    );
  }
}

/// A background notice Hermes wrote as a user turn: one line, opening to its detail.
class _BackgroundNoticeRow extends StatelessWidget {
  const _BackgroundNoticeRow({required this.id, required this.notice});
  final String id;
  final Note notice;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final key = 'notice:$id';
    final open = _isOpen(context, key, false);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _FoldButton(
        open: open,
        chevron: notice.detail.isEmpty ? _Chevron.none : _Chevron.disclosure,
        onChanged: notice.detail.isEmpty ? null : (v) => _Folds.of(context).set(key, v),
        label: [
          SizedBox(width: 14, child: Icon(Glyphs.bell, size: 12, color: p.text2)),
          const SizedBox(width: 6),
          Flexible(child: Text(notice.headline, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      if (open)
        Container(
          margin: const EdgeInsets.only(left: 20, top: 4),
          decoration: BoxDecoration(color: p.subtle, borderRadius: BorderRadius.circular(6)),
          child: _ToolTextBox(text: notice.detail, kind: _TextKind.code, maxLines: _ToolTextBox.diffMaxLines),
        ),
    ]);
  }
}

/// What the self-improvement review saved after a turn: the label in gold to purple,
/// the detail in purple, folding to one line when it is long.
class _ReviewNoteRow extends StatelessWidget {
  const _ReviewNoteRow({required this.id, required this.note});
  final String id;
  final Note note;

  static const _purple = Color(0xFF9B6BE0);
  static const _gradient = LinearGradient(colors: [Color(0xFFE8B84A), Color(0xFFC07AA0), _purple]);

  @override
  Widget build(BuildContext context) {
    final key = 'review:$id';
    final open = _isOpen(context, key, false);
    final label = ShaderMask(
      shaderCallback: (bounds) => _gradient.createShader(bounds),
      child: Text(note.headline,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFFFFFFF))),
    );
    final detail = Text(note.detail,
        maxLines: open ? null : 1,
        overflow: open ? null : TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: Color.lerp(_purple, const Color(0xFF808080), 0.42)));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _Folds.of(context).set(key, !open),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(width: 14, child: Icon(Glyphs.memory, size: 12, color: Color(0xFFD08A60))),
          const SizedBox(width: 6),
          label,
          if (note.detail.isNotEmpty) ...[const SizedBox(width: 6), Expanded(child: detail)],
        ]),
      ),
    );
  }
}

/// Stands in for the reply from the send until it shows text or a tool row: a pulsing
/// mark, the label ("Thinking…", or what Hermes says the wait is about) and the time
/// since the send, where the reply's first line will be.
class _WaitingRow extends StatefulWidget {
  const _WaitingRow({required this.waiting});
  final Waiting waiting;
  @override
  State<_WaitingRow> createState() => _WaitingRowState();
}

class _WaitingRowState extends State<_WaitingRow> with SingleTickerProviderStateMixin {
  final _appeared = DateTime.now();
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Row(children: [
      FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0.3).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
        child: Container(
            width: 8, height: 8, decoration: BoxDecoration(color: p.text2, borderRadius: BorderRadius.circular(2))),
      ),
      const SizedBox(width: 8),
      Flexible(
        child: Text(widget.waiting.label,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: p.text2)),
      ),
      const SizedBox(width: 8),
      _Ticking(
        builder: (now) => Text(elapsedText(now.difference(widget.waiting.since ?? _appeared)),
            style: TextStyle(fontSize: 14, color: p.text3, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
    ]);
  }
}

// MARK: - What was sent with a prompt

/// An image sent with a prompt: the composer's thumbnail when it was sent from here,
/// else the image from the gateway; its name until then, or if it can't be read.
class _SentImageView extends StatelessWidget {
  const _SentImageView({required this.image, required this.app});
  final SentImage image;
  final AppState app;

  Widget _thumb(Uint8List bytes) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, height: 120, fit: BoxFit.cover, gaplessPlayback: true),
      );

  @override
  Widget build(BuildContext context) {
    if (app.previews[image.localID] case final bytes?) return _thumb(bytes);
    final path = image.path;
    final chip = _FileChip(icon: Glyphs.photo, name: image.name);
    if (path == null) return chip;
    return FutureBuilder<Uint8List?>(
      future: app.sentImage(path),
      builder: (context, snapshot) => snapshot.data == null ? chip : _thumb(snapshot.data!),
    );
  }
}

/// A file sent with a prompt, by name: an image whose thumbnail isn't on this device,
/// or a file staged with `file.attach`.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.icon, required this.name});
  final IconData icon;
  final String name;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.cardStroke),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: p.text2),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.text)),
        ),
      ]),
    );
  }
}
