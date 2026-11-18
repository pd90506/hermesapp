import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'common.dart';
import 'theme.dart';
import 'transcript.dart';

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
      Expanded(child: Transcript(chat: chat, app: app, contentWidth: contentWidth)),
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

  /// The draft as last sent to the bridge: a snapshot that differs from it was
  /// changed there (a slash row accepted, a command's prefill), so the field
  /// takes it back instead of being cleared.
  String _sentDraft = '';

  /// Whether the field's own change listener is updating the controller.
  bool _syncing = false;

  /// The subagents' card is open.
  bool _subagentsOpen = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (mounted) setState(() {});
      // Typing reaches the bridge, so the slash list follows it.
      if (!_syncing) {
        _sentDraft = _controller.text;
        widget.app.setDraft(_controller.text);
      }
    });
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    // The chat just opened: the keyboard goes to its composer, as on the Mac. (A
    // TextBox's autofocus loses to the window's own focus node, which has it already.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    // The subagents reconcile while this chat shows, as the Mac's pill does.
    widget.app.startSubagentsPoll();
  }

  @override
  void dispose() {
    widget.app.stopSubagentsPoll();
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

  /// Takes back a draft the bridge changed on its own (a slash row accepted, a
  /// refused command put back), as the Mac's binding does.
  void _syncDraft() {
    final draft = _composer.draft;
    if (draft == _sentDraft) return;
    _sentDraft = draft;
    _syncing = true;
    _controller.value = TextEditingValue(text: draft, selection: TextSelection.collapsed(offset: draft.length));
    _syncing = false;
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _controller.text.trim();
    setState(() => _sending = true);
    await widget.app.send(text);
    if (!mounted) return;
    // The draft clears (or a prefill comes back) in the composer snapshot, which
    // _syncDraft takes; not here.
    setState(() => _sending = false);
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
    _syncDraft();
    // The keys the slash list takes, as the Mac's composer offers them: arrows move,
    // Tab and Return accept, Esc closes. The snapshot's own state says whether the
    // list is open, so the field's handler stays synchronous; the bridge's answer
    // (a Return the list declines) sends a beat later, through _acceptOrSend.
    void slashKey(String key) {
      widget.app.slashKey(key).then((used) {
        if (mounted) setState(() {});
      });
    }

    Future<void> acceptOrSend() async {
      final used = await widget.app.slashKey('accept');
      if (!mounted || used) return;
      await _send();
    }

    // The text, borderless: the card around it is the field (its fill, stroke and focus line).
    final field = Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
          if (composer.slashIsOpen) {
            unawaited(acceptOrSend());
          } else {
            _send();
          }
          return KeyEventResult.handled;
        }
        if (composer.slashIsOpen &&
            (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) {
          slashKey(key == LogicalKeyboardKey.arrowUp ? 'up' : 'down');
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.tab && composer.slashIsOpen) {
          slashKey('tab');
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape && (composer.slashIsOpen || composer.slashNotice != null)) {
          slashKey('escape');
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
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
                // The slash list, above what is typed: as many rows as it has, then
                // it scrolls; the picked row in the accent.
                if (composer.slashIsOpen)
                  _SlashList(app: widget.app, rows: composer.slashRows, onAccept: _focus.requestFocus)
                else if (composer.slashNotice case final notice?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    child: Text(notice,
                        maxLines: 2,
                        style: TextStyle(fontSize: 12, color: p.text2, height: 1.3)),
                  ),
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
                    _ModelPicker(app: app, onOpened: () => app.setModelPickerRequested(false)),
                    if (composer.efforts.isNotEmpty) _EffortPicker(app: app),
                    if (app.usage.gauge != null || app.usage.usage != null) _ContextRing(app: app),
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
            // The running subagents, centered above the card, as the Mac's pill.
            if (app.subagents.runs.isNotEmpty)
              _SubagentsPill(app: app, isOpen: _subagentsOpen, onToggle: () => setState(() => _subagentsOpen = !_subagentsOpen)),
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
  const _PickerButton({required this.label, required this.tooltip, required this.items, this.open, this.controller});
  final String label;
  final String tooltip;
  final List<MenuFlyoutItemBase> items;

  /// Opens the menu, when the caller owns its controller (the model picker, which
  /// `/model` can open); else this button opens its own.
  final VoidCallback? open;

  /// The caller's flyout controller; null makes this button own one.
  final FlyoutController? controller;

  static const maxMenuHeight = 360.0;

  @override
  State<_PickerButton> createState() => _PickerButtonState();
}

class _PickerButtonState extends State<_PickerButton> {
  final _own = FlyoutController();
  FlyoutController get _menu => widget.controller ?? _own;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.open case final open?) {
      open();
      return;
    }
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
/// `/model` opens it itself, through [onOpened] clearing the request.
class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.app, this.onOpened});
  final AppState app;

  /// Called once the menu opens, to clear /model's request.
  final VoidCallback? onOpened;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  final _menu = FlyoutController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen) return;
    widget.onOpened?.call();
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
        constraints: const BoxConstraints(minWidth: 160, maxHeight: 360),
        items: _items(),
      ),
    );
  }

  List<MenuFlyoutItemBase> _items() {
    final app = widget.app;
    final composer = app.composer;
    final providers = composer.providers;
    String key(String provider, String model) => '$provider\u0000$model';
    final current = providers
            ?.expand((p) => p.models.where((m) => m.isCurrent).map((m) => key(p.slug, m.model)))
            .firstOrNull ??
        '';
    return [
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final composer = app.composer;
    return _PickerButton(
      label: composer.modelLabel ?? 'Model',
      tooltip: composer.model == null ? 'Model for this chat' : 'Model for this chat: ${composer.model}',
      items: _items(),
      open: _open,
      controller: _menu,
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

/// The slash list, as the Mac's `SlashSuggestionList`: as many rows as it has
/// (about eight) before it scrolls, the picked row in the accent, a click
/// accepting the row.
class _SlashList extends StatelessWidget {
  const _SlashList({required this.app, required this.rows, required this.onAccept});
  final AppState app;
  final List<SlashRow> rows;
  final VoidCallback onAccept;

  static const maxListHeight = 220.0;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: maxListHeight),
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.cardStroke),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.all(6),
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (row.header case final header?)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 3),
                child: Text(header,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.text3)),
              ),
            HoverButton(
              onPressed: () {
                app.acceptSlashRow(row.id);
                onAccept();
              },
              builder: (context, states) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: row.isSelected || states.isHovered ? p.subtle : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Text(row.display, style: TextStyle(fontSize: 13, color: p.text)),
                  if (row.meta case final meta? when meta.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(meta,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: p.text3)),
                    ),
                  ] else
                    const Spacer(),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// How full the chat's context is, as the Mac's `ContextGaugeButton`: a ring
/// filling with the context used and its percentage, opening what fills it and
/// the session's counters.
class _ContextRing extends StatelessWidget {
  const _ContextRing({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final usage = app.usage;
    final gauge = usage.gauge;
    final menu = FlyoutController();
    final summary = gauge == null
        ? 'Token use'
        : 'Context: ${gauge.isEstimated ? '~' : ''}${tokens(gauge.used)} of ${tokens(gauge.max)} tokens (${gauge.percent}%)';
    return Tooltip(
      message: summary,
      child: FlyoutTarget(
        controller: menu,
        child: HoverButton(
          onPressed: () => menu.showFlyout<void>(
            placementMode: FlyoutPlacementMode.topLeft,
            barrierColor: const Color(0x00000000),
            additionalOffset: 4,
            builder: (context) => FlyoutContent(
              constraints: const BoxConstraints(minWidth: 280),
              child: _ContextDetails(usage: usage),
            ),
          ),
          builder: (context, states) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: states.isHovered ? p.subtle : const Color(0x00000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CustomPaint(painter: _RingPainter(fraction: gauge?.fraction ?? 0)),
              ),
              if (gauge != null) ...[
                const SizedBox(width: 5),
                Text('${gauge.isEstimated ? '~' : ''}${gauge.percent}%',
                    style: TextStyle(fontSize: 12, color: p.text2)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  /// 950, 12.8K, 1.2M.
  static String tokens(int count) {
    if (count < 1000) return '$count';
    if (count < 1000000) {
      final value = count / 1000;
      return '${value >= 100 ? value.round() : (value * 10).round() / 10}K';
    }
    final value = count / 1000000;
    return '${(value * 10).round() / 10}M';
  }
}

/// The ring: filling clockwise from the top, orange past 80 %, red past 95 %, as
/// the context nears the point Hermes compresses it.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction});
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = size.width / 2;
    final center = Offset(edge, edge);
    final radius = edge - 1.5;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color.fromRGBO(128, 128, 128, 0.4);
    canvas.drawCircle(center, radius, track);
    if (fraction > 0) {
      final color = fraction > 0.95
          ? const Color(0xFFC42B1C)
          : fraction > 0.8
              ? const Color(0xFFF7630C)
              : const Color(0xFF0078D4);
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, 2 * math.pi * fraction, false, arc);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction;
}

/// The gauge's details: the context, what fills it, then the session's counters.
class _ContextDetails extends StatelessWidget {
  const _ContextDetails({required this.usage});
  final UsageSnapshot usage;

  /// Orange past 80 %, red past 95 %, as the context nears its compression.
  static Color _barColor(double fraction) {
    if (fraction > 0.95) return const Color(0xFFC42B1C);
    if (fraction > 0.8) return const Color(0xFFF7630C);
    return const Color(0xFF0078D4);
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final gauge = usage.gauge;
    final breakdown = usage.breakdown;
    final counters = usage.usage;
    // What the categories leave out of the measured occupancy.
    final unitemized = (breakdown == null || gauge == null || gauge.isEstimated)
        ? 0
        : breakdown.contextUsed - breakdown.categories.fold<int>(0, (sum, c) => sum + c.tokens);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: p.text2))),
            Text(value, style: TextStyle(fontSize: 12, color: p.text)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (gauge != null) ...[
        Text('Context', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 4,
            color: p.subtle2,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: gauge.fraction,
              child: Container(color: _barColor(gauge.fraction)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${gauge.isEstimated ? '~' : ''}${_ContextRing.tokens(gauge.used)} of ${_ContextRing.tokens(gauge.max)} tokens (${gauge.percent}%)',
          style: TextStyle(fontSize: 12, color: p.text),
        ),
        if (gauge.isEstimated)
          Text('Estimated until a reply measures it.', style: TextStyle(fontSize: 11, color: p.text3)),
      ],
      if (breakdown != null && breakdown.categories.isNotEmpty) ...[
        const SizedBox(height: 10),
        for (final category in breakdown.categories)
          row(category.label, '~${_ContextRing.tokens(category.tokens)}'),
        if (unitemized > 0) row('Not itemized', '~${_ContextRing.tokens(unitemized)}'),
        if (gauge != null && !gauge.isEstimated)
          Text("Items are estimates. The total is the model's own count.",
              style: TextStyle(fontSize: 11, color: p.text3)),
      ],
      if (counters != null) ...[
        const SizedBox(height: 10),
        row('Tokens', '${_ContextRing.tokens(counters.total)} in, ${_ContextRing.tokens(counters.output)} out'),
        row('Model calls', '${counters.calls}'),
        if (counters.cacheHitPercent case final hit?) row('Cache hits', '$hit%'),
        if (counters.tokensPerSecond case final speed?) row('Speed', '${speed.toStringAsFixed(1)} tokens/s'),
        if (counters.costUSD case final cost?) row('Cost', '\$${cost.toStringAsFixed(3)}'),
        if (counters.model case final model?) row('Model', model),
      ],
    ]);
  }
}

/// The running subagents, as the Mac's `SubagentsPill`: a pill above the composer
/// ("2 subagents", spinning) that opens into a card as wide as it, each child with
/// its goal, what it did last, a field to steer it and Stop.
class _SubagentsPill extends StatelessWidget {
  const _SubagentsPill({required this.app, required this.isOpen, required this.onToggle});
  final AppState app;
  final bool isOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final runs = app.subagents.runs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (isOpen)
        _SubagentsPanel(app: app, runs: runs, onClose: onToggle)
      else
        Center(
          child: HoverButton(
            onPressed: onToggle,
            builder: (context, states) => Container(
              padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
              decoration: BoxDecoration(
                color: states.isHovered ? p.layer : p.card,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: p.layerStroke),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 13, height: 13, child: ProgressRing(strokeWidth: 2)),
                const SizedBox(width: 7),
                Text('${runs.length} subagent${runs.length == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.text2)),
              ]),
            ),
          ),
        ),
      const SizedBox(height: 8),
    ]);
  }
}

/// The pill's card: every running child, one row each.
class _SubagentsPanel extends StatelessWidget {
  const _SubagentsPanel({required this.app, required this.runs, required this.onClose});
  final AppState app;
  final List<SubagentRun> runs;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.cardStroke),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('${runs.length} subagent${runs.length == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text)),
          const Spacer(),
          IconAction(Glyphs.cancel, size: 10, tooltip: 'Close', onPressed: onClose),
        ]),
        for (final run in runs) _SubagentRow(app: app, run: run),
      ]),
    );
  }
}

/// One child: its goal and how long it has run, its newest lines, and Steer/Stop.
class _SubagentRow extends StatefulWidget {
  const _SubagentRow({required this.app, required this.run});
  final AppState app;
  final SubagentRun run;

  @override
  State<_SubagentRow> createState() => _SubagentRowState();
}

class _SubagentRowState extends State<_SubagentRow> {
  final _steer = TextEditingController();

  @override
  void dispose() {
    _steer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final run = widget.run;
    final age = DateTime.now().difference(run.startedAt ?? DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(run.goal,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.text)),
          ),
          const SizedBox(width: 8),
          Text(run.status == 'queued' ? 'Queued' : '${age.inSeconds}s',
              style: TextStyle(fontSize: 11, color: p.text3)),
        ]),
        for (final line in run.activity.take(3))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(line.text,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: line.isError ? p.critical : p.text3)),
          ),
        const SizedBox(height: 5),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 28,
              child: TextBox(
                controller: _steer,
                placeholder: 'Steer this subagent…',
                placeholderStyle: TextStyle(fontSize: 12, color: p.text3),
                style: TextStyle(fontSize: 12, color: p.text),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onSubmitted: (text) {
                  if (text.trim().isNotEmpty) widget.app.steerSubagent(run.id, text);
                  _steer.clear();
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Stop this subagent',
            child: SizedBox(
              width: 28,
              height: 28,
              child: Button(
                onPressed: () => widget.app.stopSubagent(run.id),
                style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.zero)),
                child: const Icon(Glyphs.stop, size: 11),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}
