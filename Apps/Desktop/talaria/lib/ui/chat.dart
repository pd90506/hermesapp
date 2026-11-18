import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'common.dart';
import 'markdown.dart';
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
      // In the title bar's band, which moves the window (`native_frame.cpp`): the title
      // only, clear of the caption buttons Windows draws at its end. The chat's commands
      // are in its row's context menu, as on the Mac.
      Container(
        height: WindowTitleBar.height,
        padding: const EdgeInsets.fromLTRB(24, 0, WindowTitleBar.captionButtonsWidth + 12, 0),
        alignment: Alignment.centerLeft,
        child: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: p.text)),
      ),
      Expanded(child: _Transcript(chat: chat, app: app)),
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
      // One composer per chat, which takes the keyboard as the chat opens.
      Composer(key: ValueKey(chat.sessionID), app: app),
    ]);
  }

}

/// The transcript, newest at the bottom; it follows the end while a reply streams.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.chat, required this.app});
  final ChatSnapshot chat;
  final AppState app;

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
              _Single(:final item) => _MessageView(item: item, app: app),
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
  const _MessageView({required this.item, required this.app});
  final ChatItem item;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final body = TextStyle(fontSize: 14, color: p.text, height: 1.55);
    switch (item.role) {
      case Role.user:
        final sent = item.images.isNotEmpty || item.attachments.isNotEmpty;
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              // What was sent with the prompt, above its bubble, as on the Mac.
              if (sent)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: [
                    for (final image in item.images) _SentImageView(image: image, app: app),
                    for (final name in item.attachments) _FileChip(icon: Glyphs.document, name: name),
                  ]),
                ),
              if (item.text.trim().isNotEmpty || !sent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(color: p.userBubble, borderRadius: BorderRadius.circular(8)),
                  child: SelectableText(item.text, style: body.copyWith(height: 1.45)),
                ),
            ]),
          ),
        );
      case Role.system:
        return Text(item.text, style: TextStyle(fontSize: 12, color: p.text2));
      case Role.assistant:
      case Role.tool:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((item.reasoning ?? '').isNotEmpty) _Reasoning(text: item.reasoning!, parts: item.reasoningMarkdown),
          if (item.markdown.isNotEmpty)
            _Selectable(child: MarkdownBody(parts: item.markdown))
          else if (item.text.trim().isNotEmpty)
            SelectableText(item.text.trim(), style: body),
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

/// A reply's reasoning, folded under one line, as the Mac's.
class _Reasoning extends StatefulWidget {
  const _Reasoning({required this.text, this.parts = const []});
  final String text;
  final List<MdPart> parts;
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
            child: widget.parts.isNotEmpty
                ? _Selectable(child: MarkdownBody(parts: widget.parts, secondary: true))
                : SelectableText(widget.text.trim(), style: TextStyle(fontSize: 13, color: p.text2, height: 1.5)),
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

/// The composer: the attached images and files as cards, a multi-line TextBox with its
/// command at its end (Enter sends, Shift+Enter starts a new line; Stop while a reply
/// runs), and a toolbar under it with Attach and the model and reasoning-effort pickers,
/// as the Mac's composer. Files can also be dropped on the window, or pasted.
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

  /// The model switch whose confirmation is showing, so it is asked once.
  PendingModelSwitch? _asking;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _focus.addListener(() => setState(() {}));
    // The chat just opened: the keyboard goes to its composer, as on the Mac. (A
    // TextBox's autofocus loses to the window's own focus node, which has it already.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  ComposerSnapshot get _composer => widget.app.composer;

  bool get _hasCards => _composer.attachments.isNotEmpty;

  bool get _canSend =>
      (_controller.text.trim().isNotEmpty || _hasCards) &&
      !_sending &&
      _composer.uploadingFiles.isEmpty &&
      !_composer.attachments.any((a) => a.isUploading) &&
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

  /// Ctrl+V: files and images on the clipboard are attached; text is inserted.
  Future<void> _paste() async {
    if (!await widget.app.pasteIsText()) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted) return;
    final value = _controller.value;
    final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  /// A switch the gateway wants confirmed (an expensive model): asked in a dialog, as
  /// the Mac asks in an alert.
  void _askAboutSwitch() {
    final pending = _composer.pendingModelSwitch;
    if (pending == null || identical(pending, _asking) || _asking?.model == pending.model) return;
    _asking = pending;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => ContentDialog(
          title: const Text('Switch model?'),
          content: Text(pending.message),
          actions: [
            Button(child: const Text('Keep current model'), onPressed: () => Navigator.pop(context, false)),
            FilledButton(child: Text('Switch to ${pending.label}'), onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      );
      _asking = null;
      if (ok == true) {
        await widget.app.confirmModelSwitch();
      } else {
        await widget.app.cancelModelSwitch();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final app = widget.app;
    final composer = _composer;
    final running = app.chat.isRunning;
    final focused = _focus.hasFocus;
    _askAboutSwitch();
    // The text, borderless: the card around it is the field (its fill, stroke and focus line).
    final field = Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
          _send();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
          _paste();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextBox(
        controller: _controller,
        focusNode: _focus,
        placeholder: 'Message Hermes',
        placeholderStyle: TextStyle(fontSize: 14, height: 1.45, color: p.text3),
        minLines: 1,
        maxLines: 10,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        style: TextStyle(fontSize: 14, height: 1.45, color: p.text),
        // No box of its own: a transparent border replaces the TextBox's default stroke.
        decoration: const WidgetStatePropertyAll(
            BoxDecoration(color: Color(0x00000000), border: Border.fromBorderSide(BorderSide(color: Color(0x00000000))))),
        foregroundDecoration: const WidgetStatePropertyAll(BoxDecoration()),
        highlightColor: const Color(0x00000000),
        unfocusedColor: const Color(0x00000000),
      ),
    );
    final Widget action;
    if (running && _controller.text.trim().isEmpty && !_hasCards) {
      action = _ComposerAction(icon: Glyphs.stop, iconSize: 12, tooltip: 'Stop the reply', onPressed: app.interrupt);
    } else {
      action = _ComposerAction(
        icon: Glyphs.send,
        tooltip: running ? 'Send now (Enter); Hermes takes it in during the reply' : 'Send (Enter)',
        busy: _sending || composer.isSubmitting,
        onPressed: _canSend ? _send : null,
      );
    }
    // One card, as Windows 11's own chat boxes and Hermes Desktop's composer: the cards,
    // the text, and a row of commands along the bottom with Send at its end. It wears
    // WinUI's text field colours, and its accent line along the bottom when focused (or
    // while files are dragged over the window).
    final card = MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        onTap: _focus.requestFocus,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: focused ? p.inputFocusedFill : p.inputFill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: app.isDraggingFiles ? p.accent : p.inputStroke),
            ),
            child: Stack(children: [
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                if (composer.hasCards)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final card in composer.attachments)
                        _AttachmentCardView(
                            card: card, preview: app.previews[card.id], onRemove: () => app.removeAttachment(card.id)),
                      for (final name in composer.uploadingFiles) _AttachmentCardView.uploading(name),
                    ]),
                  ),
                field,
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 8, 8),
                  child: Row(children: [
                    IconAction(Glyphs.attach, size: 15, tooltip: 'Attach images or files', onPressed: app.pickFiles),
                    const SizedBox(width: 2),
                    _ModelPicker(app: app),
                    if (composer.efforts.isNotEmpty) _EffortPicker(app: app),
                    const Spacer(),
                    action,
                  ]),
                ),
              ]),
              // WinUI's focus line: 2 px of accent along the bottom edge.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: focused || app.isDraggingFiles ? 2 : 1,
                child: ColoredBox(color: focused || app.isDraggingFiles ? p.accent : p.inputStrongStroke),
              ),
            ]),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ChatPane.contentWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            if (composer.error case final message?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InfoBar(
                  title: Text(message),
                  severity: InfoBarSeverity.warning,
                  onClose: app.dismissComposerError,
                ),
              ),
            card,
          ]),
        ),
      ),
    );
  }
}

/// Send or Stop: WinUI's accent button, icon only, 32 px square, at the end of the
/// composer's command row. Disabled, it takes the system's disabled accent colours.
class _ComposerAction extends StatelessWidget {
  const _ComposerAction({required this.icon, required this.tooltip, this.onPressed, this.busy = false, this.iconSize = 14});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 32,
        height: 32,
        child: FilledButton(
          onPressed: onPressed,
          style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.zero)),
          child: Center(
            child: busy
                ? const SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2))
                : Icon(icon, size: iconSize),
          ),
        ),
      ),
    );
  }
}

/// The toolbar's pickers: a subtle button with the current value and a chevron, which
/// opens a menu (WinUI's MenuFlyout, the button borderless as a command bar's). As the
/// Mac's composer menus: it opens upward from the pill, its left edge on the pill's, and
/// it slides up into place. A long list stops at [maxMenuHeight] and scrolls.
class _PickerButton extends StatefulWidget {
  const _PickerButton({required this.label, required this.tooltip, required this.items});
  final String label;
  final String tooltip;
  final List<MenuFlyoutItemBase> items;

  static const maxMenuHeight = 360.0;

  @override
  State<_PickerButton> createState() => _PickerButtonState();
}

class _PickerButtonState extends State<_PickerButton> {
  final _menu = FlyoutController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen) return;
    _menu.showFlyout<void>(
      placementMode: FlyoutPlacementMode.topLeft,
      barrierColor: const Color(0x00000000),
      additionalOffset: 4,
      transitionBuilder: (context, animation, placement, flyout) => ClipRect(
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: FluentTheme.of(context).animationCurve)),
          child: FadeTransition(opacity: animation, child: flyout),
        ),
      ),
      builder: (context) => MenuFlyout(
        constraints: const BoxConstraints(minWidth: 160, maxHeight: _PickerButton.maxMenuHeight),
        items: widget.items,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: FlyoutTarget(
        controller: _menu,
        child: HoverButton(
          onPressed: _open,
          builder: (context, states) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: states.isHovered ? p.subtle : const Color(0x00000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.label, style: TextStyle(fontSize: 12, color: p.text2)),
              const SizedBox(width: 6),
              Icon(Glyphs.chevronDown, size: 8, color: p.text3),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A menu's section title, as WinUI menus head a group. (A menu is in the overlay,
/// outside the window's PaletteScope: its colours come from the Fluent theme.)
MenuFlyoutItemBase _menuHeader(String title) => MenuFlyoutItemBuilder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: FluentTheme.of(context).resources.textFillColorSecondary)),
      ),
    );

/// The chat's model, by provider, as the Mac's model menu (Desktop's model picker).
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final composer = app.composer;
    final providers = composer.providers;
    String key(String provider, String model) => '$provider\u0000$model';
    final current = providers
            ?.expand((p) => p.models.where((m) => m.isCurrent).map((m) => key(p.slug, m.model)))
            .firstOrNull ??
        '';
    return _PickerButton(
      label: composer.modelLabel ?? 'Model',
      tooltip: composer.model == null ? 'Model for this chat' : 'Model for this chat: ${composer.model}',
      items: [
        if (providers == null)
          MenuFlyoutItem(text: const Text('Loading models…'), onPressed: null)
        else if (providers.isEmpty)
          MenuFlyoutItem(text: const Text('No models available'), onPressed: null)
        else
          for (final provider in providers) ...[
            _menuHeader(provider.name),
            for (final model in provider.models)
              RadioMenuFlyoutItem<String>(
                text: Text(model.label),
                value: key(provider.slug, model.model),
                groupValue: current,
                onChanged: (_) => app.selectModel(provider.slug, model.model),
              ),
          ],
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(leading: const Icon(Glyphs.refresh), text: const Text('Reload models'), onPressed: app.reloadModels),
      ],
    );
  }
}

/// The chat's reasoning effort, for a model that has the control.
class _EffortPicker extends StatelessWidget {
  const _EffortPicker({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final composer = app.composer;
    return _PickerButton(
      label: composer.effortLabel,
      tooltip: 'Reasoning effort for this chat',
      items: [
        _menuHeader('Reasoning effort'),
        for (final choice in composer.efforts)
          RadioMenuFlyoutItem<String>(
            text: Text(choice.label),
            value: choice.value,
            groupValue: composer.effort,
            onChanged: (value) => app.selectEffort(value),
          ),
      ],
    );
  }
}

/// An attached image or file, above the text box: its thumbnail or icon, its name and
/// size, and Remove. A card still uploading shows a ring; a failed image upload a
/// warning (the send uploads it again).
class _AttachmentCardView extends StatelessWidget {
  const _AttachmentCardView({required this.card, this.preview, this.onRemove}) : uploadingName = null;
  const _AttachmentCardView.uploading(String name)
      : uploadingName = name,
        card = null,
        preview = null,
        onRemove = null;

  final AttachmentCard? card;
  final String? uploadingName;
  final Uint8List? preview;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final card = this.card;
    final uploading = uploadingName != null || (card?.isUploading ?? false);
    final failure = card?.failure;
    Widget thumb;
    if (preview case final bytes?) {
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(bytes, width: 36, height: 36, fit: BoxFit.cover, gaplessPlayback: true),
      );
    } else {
      thumb = Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: p.subtle, borderRadius: BorderRadius.circular(4)),
        child: Icon((card?.isImage ?? false) ? Glyphs.photo : Glyphs.document, size: 16, color: p.text2),
      );
    }
    return Container(
      width: 220,
      padding: const EdgeInsets.fromLTRB(6, 6, 2, 6),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: failure != null ? p.caution : p.cardStroke),
      ),
      child: Row(children: [
        thumb,
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(card?.name ?? uploadingName ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.text)),
            Text(
              failure ?? (uploading ? 'Uploading…' : card?.detail ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: failure != null ? p.caution : p.text3),
            ),
          ]),
        ),
        if (uploading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
          ),
        if (onRemove != null) IconAction(Glyphs.cancel, size: 10, tooltip: 'Remove', onPressed: onRemove),
      ]),
    );
  }
}
