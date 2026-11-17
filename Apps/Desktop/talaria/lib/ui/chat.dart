import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'common.dart';
import 'theme.dart';

/// The open chat: a header with its title and commands, the transcript, the composer.
class ChatPane extends StatelessWidget {
  const ChatPane({super.key, required this.app});
  final AppState app;

  static const contentWidth = 760.0;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final chat = app.chat;
    if (!chat.isOpen) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Glyphs.chat, size: 40, color: p.text3),
          const SizedBox(height: 12),
          Text('No chat selected', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: p.text)),
          const SizedBox(height: 4),
          Text(
              app.connection.state == LinkState.connected
                  ? 'Pick a session, or start a new chat.'
                  : 'Connect to your Hermes dashboard in Settings.',
              style: TextStyle(fontSize: 14, color: p.text2)),
        ]),
      );
    }
    final title = (chat.title?.isNotEmpty ?? false) ? chat.title! : 'New chat';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 56,
        padding: const EdgeInsets.fromLTRB(24, 0, 12, 0),
        child: Row(children: [
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: p.text)),
          ),
          DropDownButton(
            title: const Icon(Glyphs.more, size: 16),
            trailing: const SizedBox.shrink(),
            items: [
              MenuFlyoutItem(
                leading: const Icon(Glyphs.copy),
                text: const Text('Copy conversation'),
                onPressed: () => Clipboard.setData(ClipboardData(text: _plainText(chat))),
              ),
              MenuFlyoutItem(
                leading: const Icon(Glyphs.delete),
                text: const Text('Delete chat'),
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ),
        ]),
      ),
      Expanded(child: _Transcript(chat: chat)),
      if (chat.lastError case final error?)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: contentWidth),
              child: InfoBar(title: const Text('Hermes reported an error'), content: Text(error), severity: InfoBarSeverity.error),
            ),
          ),
        ),
      Composer(app: app),
    ]);
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Delete this chat?'),
        content: const Text('It is deleted on the server, for every app that shows it.'),
        actions: [
          Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context, false)),
          FilledButton(child: const Text('Delete'), onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) await app.deleteChat();
  }

  static String _plainText(ChatSnapshot chat) => chat.items
      .where((i) => i.role == Role.user || i.role == Role.assistant)
      .map((i) => '${i.role == Role.user ? 'You' : 'Hermes'}: ${i.text}')
      .join('\n\n');
}

/// The transcript, newest at the bottom; it follows the end while a reply streams.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.chat});
  final ChatSnapshot chat;

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks(chat.items);
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      itemCount: blocks.length + (chat.isRunning && !_hasActiveTool(chat) ? 1 : 0),
      itemBuilder: (context, index) {
        if (chat.isRunning && !_hasActiveTool(chat)) {
          if (index == 0) return const _Centered(child: _Working());
          index -= 1;
        }
        final block = blocks[blocks.length - 1 - index];
        return _Centered(
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: switch (block) {
              _ToolRun(:final items) => _ToolCard(items: items),
              _Single(:final item) => _MessageView(item: item),
            },
          ),
        );
      },
    );
  }

  static bool _hasActiveTool(ChatSnapshot chat) => chat.items.any((i) => i.role == Role.tool && i.isActive);

  /// Consecutive tool calls in one card, as Desktop and the Mac fold a turn's steps.
  static List<_Block> _blocks(List<ChatItem> items) {
    final blocks = <_Block>[];
    for (final item in items) {
      if (item.role == Role.tool) {
        if (blocks.lastOrNull case _ToolRun(:final items)) {
          items.add(item);
        } else {
          blocks.add(_ToolRun([item]));
        }
      } else if (item.role != Role.assistant || item.text.trim().isNotEmpty || (item.reasoning ?? '').isNotEmpty) {
        blocks.add(_Single(item));
      }
    }
    return blocks;
  }
}

sealed class _Block {}

class _Single extends _Block {
  _Single(this.item);
  final ChatItem item;
}

class _ToolRun extends _Block {
  _ToolRun(this.items);
  final List<ChatItem> items;
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: ChatPane.contentWidth), child: child),
      );
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.item});
  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final body = TextStyle(fontSize: 14, color: p.text, height: 1.55);
    switch (item.role) {
      case Role.user:
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(color: p.userBubble, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(item.text, style: body.copyWith(height: 1.45)),
            ),
          ),
        );
      case Role.system:
        return Text(item.text, style: TextStyle(fontSize: 12, color: p.text2));
      case Role.assistant:
      case Role.tool:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((item.reasoning ?? '').isNotEmpty) _Reasoning(text: item.reasoning!),
          if (item.text.trim().isNotEmpty) SelectableText(item.text.trim(), style: body),
          if (item.text.trim().isNotEmpty && !item.isActive)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                IconAction(Glyphs.copy,
                    size: 13, tooltip: 'Copy', onPressed: () => Clipboard.setData(ClipboardData(text: item.text))),
                if (item.timestamp case final t?)
                  Text(_clock(t), style: TextStyle(fontSize: 12, color: p.text3)),
              ]),
            ),
        ]);
    }
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// A reply's reasoning, folded under one line, as the Mac's.
class _Reasoning extends StatefulWidget {
  const _Reasoning({required this.text});
  final String text;
  @override
  State<_Reasoning> createState() => _ReasoningState();
}

class _ReasoningState extends State<_Reasoning> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HoverButton(
          onPressed: () => setState(() => _open = !_open),
          builder: (context, states) => Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Reasoning', style: TextStyle(fontSize: 13, color: states.isHovered ? p.text : p.text2)),
            const SizedBox(width: 6),
            Icon(_open ? Glyphs.chevronUp : Glyphs.chevronDown, size: 9, color: p.text3),
          ]),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(widget.text.trim(), style: TextStyle(fontSize: 13, color: p.text2, height: 1.5)),
          ),
      ]),
    );
  }
}

/// A turn's tool calls, in an Expander-style card: a line each.
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.items});
  final List<ChatItem> items;
  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final active = widget.items.any((i) => i.isActive);
    final n = widget.items.length;
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.cardStroke),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HoverButton(
          onPressed: () => setState(() => _open = !_open),
          builder: (context, states) => Row(children: [
            if (active)
              const SizedBox(width: 13, height: 13, child: ProgressRing(strokeWidth: 2))
            else
              Icon(Glyphs.checkMark, size: 13, color: p.success),
            const SizedBox(width: 10),
            Text(active ? 'Working' : 'Used $n tool${n == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 13, color: p.text)),
            const Spacer(),
            Icon(_open ? Glyphs.chevronUp : Glyphs.chevronDown, size: 10, color: p.text2),
          ]),
        ),
        if (_open) ...[
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Container(height: 1, color: p.divider)),
          for (final item in widget.items) _ToolLine(item: item),
        ],
      ]),
    );
  }
}

class _ToolLine extends StatelessWidget {
  const _ToolLine({required this.item});
  final ChatItem item;
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final detail = (item.detail ?? item.text).split('\n').first.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        if (item.isActive)
          const SizedBox(width: 13, height: 13, child: ProgressRing(strokeWidth: 2))
        else
          Icon(Glyphs.tool, size: 13, color: p.text2),
        const SizedBox(width: 10),
        Text(item.toolName ?? 'tool', style: TextStyle(fontFamily: monoFont, fontSize: 12, color: p.text)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: monoFont, fontSize: 12, color: p.text3)),
        ),
      ]),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();
  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(children: [
        const SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text('Hermes is working…', style: TextStyle(fontSize: 13, color: p.text2)),
      ]),
    );
  }
}

/// A multi-line TextBox with its command along the bottom: Enter sends, Shift+Enter
/// starts a new line; Stop while a reply runs.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.app});
  final AppState app;
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canSend =>
      _controller.text.trim().isNotEmpty &&
      !_sending &&
      widget.app.connection.state == LinkState.connected;

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _controller.text.trim();
    setState(() => _sending = true);
    final ok = await widget.app.send(text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.app.chat.isRunning;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ChatPane.contentWidth),
          child: Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                _send();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextBox(
              controller: _controller,
              focusNode: _focus,
              placeholder: 'Message Hermes',
              minLines: 2,
              maxLines: 8,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              style: const TextStyle(fontSize: 14, height: 1.45),
              suffixMode: OverlayVisibilityMode.always,
              suffix: Padding(
                padding: const EdgeInsets.all(6),
                child: running && _controller.text.trim().isEmpty
                    ? Tooltip(
                        message: 'Stop the reply',
                        child: FilledButton(
                          onPressed: widget.app.interrupt,
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Glyphs.stop, size: 11),
                            SizedBox(width: 6),
                            Text('Stop'),
                          ]),
                        ),
                      )
                    : Tooltip(
                        message: running ? 'Send now (Enter); Hermes takes it in during the reply' : 'Send (Enter)',
                        child: FilledButton(
                          onPressed: _canSend ? _send : null,
                          child: _sending
                              ? const SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2))
                              : const Icon(Glyphs.send, size: 14),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
