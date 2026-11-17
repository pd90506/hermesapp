import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../app/snapshots.dart';
import '../platform/win32.dart';
import 'theme.dart';

/// Lays out a message HermesKit parsed (docs/desktop-bridge.md, "Markdown"): prose as
/// paragraphs of styled runs, code blocks and tables as their own components, as the Mac
/// app's `MarkdownView` does. No parsing here; the runs say what each piece is.
class MarkdownBody extends StatelessWidget {
  const MarkdownBody({super.key, required this.parts, this.secondary = false});
  final List<MdPart> parts;

  /// Reasoning: smaller and in the secondary text colour.
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final base = TextStyle(fontSize: secondary ? 13 : 14, color: secondary ? p.text2 : p.text, height: 1.55);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (index, part) in parts.indexed)
        Padding(
          key: ValueKey(part.id),
          padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
          child: switch (part) {
            MdPart(:final prose?) => _Prose(runs: prose, base: base),
            MdPart(:final code?) => CodeBlock(code: code),
            MdPart(:final table?) => _TableView(table: table, base: base),
            _ => const SizedBox.shrink(),
          },
        ),
    ]);
  }
}

/// One paragraph of prose: its runs up to a separator, with the indents and gap of its
/// first run.
class _Paragraph {
  _Paragraph(this.runs);
  final List<MdRun> runs;
  List<String> get indents => runs.first.indents;
  String? get gap => runs.first.gap;
  bool get hasMarker => runs.first.role == 'listMarker';
}

const _listIndent = 24.0;
const _quoteIndent = 14.0;

double _gap(String? gap) => switch (gap) {
      'block' => 10,
      'listItem' => 4,
      _ => 0,
    };

/// Prose: paragraphs grouped by their indents, so a quote's bar runs down all its
/// paragraphs and a list's items share its indent.
class _Prose extends StatelessWidget {
  const _Prose({required this.runs, required this.base});
  final List<MdRun> runs;
  final TextStyle base;

  static List<_Paragraph> paragraphs(List<MdRun> runs) {
    final out = <_Paragraph>[];
    var current = <MdRun>[];
    for (final run in runs) {
      if (run.role == 'separator') {
        if (current.isNotEmpty) out.add(_Paragraph(current));
        current = [];
      } else {
        current.add(run);
      }
    }
    if (current.isNotEmpty) out.add(_Paragraph(current));
    return out;
  }

  @override
  Widget build(BuildContext context) => _group(context, paragraphs(runs), 0);

  Widget _group(BuildContext context, List<_Paragraph> paras, int depth) {
    final p = PaletteScope.of(context);
    final children = <Widget>[];
    var i = 0;
    while (i < paras.length) {
      final first = paras[i];
      Widget child;
      if (first.indents.length > depth) {
        // A nested group: every following paragraph with the same indent at this depth.
        final kind = first.indents[depth];
        var j = i + 1;
        while (j < paras.length && paras[j].indents.length > depth && paras[j].indents[depth] == kind) {
          j++;
        }
        final inner = _group(context, paras.sublist(i, j), depth + 1);
        child = kind == 'quote'
            ? Container(
                padding: const EdgeInsets.only(left: _quoteIndent - 3),
                decoration: BoxDecoration(border: Border(left: BorderSide(color: p.text3, width: 3))),
                child: DefaultTextStyle.merge(style: TextStyle(color: p.text2), child: inner),
              )
            : Padding(padding: const EdgeInsets.only(left: _listIndent), child: inner);
        i = j;
      } else {
        child = _leaf(context, first);
        i++;
      }
      children.add(Padding(
        padding: EdgeInsets.only(top: children.isEmpty ? 0 : _gap(first.gap)),
        child: child,
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _leaf(BuildContext context, _Paragraph para) {
    final p = PaletteScope.of(context);
    final runs = para.runs;
    // A thematic break comes as one run of box-drawing dashes.
    if (runs.length == 1 && runs.first.role == 'body' && RegExp(r'^─+$').hasMatch(runs.first.text)) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Container(height: 1, color: p.divider));
    }
    // A code block nested in a list or quote stays in the prose: its label, then its code.
    if (runs.any((r) => r.role == 'code')) {
      final code = runs.where((r) => r.role == 'code').map((r) => r.text).join();
      final language = runs.where((r) => r.role == 'codeLanguage').map((r) => r.text.trim()).join();
      return CodeBlock(code: MdCode(language: language.isEmpty ? null : language, text: code));
    }
    final marker = para.hasMarker ? runs.first.text.trim() : null;
    final text = RunText(runs: para.hasMarker ? runs.sublist(1) : runs, base: base);
    if (marker == null) return text;
    // The marker hangs in the list's indent, left of the item's text.
    return Stack(clipBehavior: Clip.none, children: [
      text,
      Positioned(
        left: -_listIndent,
        width: _listIndent - 6,
        top: 0,
        child: switch (marker) {
          // A task list's box, in the Fluent glyphs rather than the emoji font's.
          '☑' || '☐' => Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(top: ((base.fontSize ?? 14) * (base.height ?? 1.5) - 14) / 2),
                child: Icon(marker == '☑' ? Glyphs.checkboxChecked : Glyphs.checkbox,
                    size: 14, color: marker == '☑' ? p.accent : p.text2),
              ),
            ),
          _ => Text(marker,
              textAlign: TextAlign.right,
              style: base.copyWith(color: p.text2, fontFeatures: const [FontFeature.tabularFigures()])),
        },
      ),
    ]);
  }
}

/// Runs as one rich text, each styled by its role and flags. Links open in the browser.
class RunText extends StatefulWidget {
  const RunText({super.key, required this.runs, required this.base, this.textAlign = TextAlign.start});
  final List<MdRun> runs;
  final TextStyle base;
  final TextAlign textAlign;

  @override
  State<RunText> createState() => _RunTextState();
}

class _RunTextState extends State<RunText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  TextStyle _style(MdRun run, Palette p) {
    var style = widget.base;
    switch (run.role) {
      case 'heading':
        final size = switch (run.level ?? 6) { 1 => 20.0, 2 => 18.0, 3 => 16.0, _ => style.fontSize ?? 14 };
        style = style.copyWith(fontSize: size, fontWeight: FontWeight.w600, height: 1.4);
      case 'tableHeader':
        style = style.copyWith(fontWeight: FontWeight.w600);
      case 'math':
        style = style.copyWith(fontFamily: monoFont, fontSize: (style.fontSize ?? 14) - 1, backgroundColor: p.codeBg);
    }
    if (run.bold) style = style.copyWith(fontWeight: FontWeight.w600);
    if (run.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (run.strike) style = style.copyWith(decoration: TextDecoration.lineThrough);
    if (run.inlineCode) {
      style = style.copyWith(fontFamily: monoFont, fontSize: (style.fontSize ?? 14) - 1, backgroundColor: p.codeBg);
    }
    if (run.link != null) {
      style = style.copyWith(color: p.accent, decoration: TextDecoration.underline, decorationColor: p.accent.withValues(alpha: 0.5));
    }
    return style;
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    _clear();
    final spans = <InlineSpan>[];
    for (final run in widget.runs) {
      // Math is shown as its source until the app typesets it.
      final text = run.role == 'math' ? (run.display ? run.text : ' ${run.text} ') : run.text;
      TapGestureRecognizer? tap;
      if (run.link case final link?) {
        tap = TapGestureRecognizer()..onTap = () => openLink(link);
        _recognizers.add(tap);
      }
      spans.add(TextSpan(
        text: text,
        style: _style(run, p),
        recognizer: tap,
        mouseCursor: tap != null ? SystemMouseCursors.click : null,
      ));
    }
    return Text.rich(TextSpan(children: spans), textAlign: widget.textAlign);
  }
}

/// A fenced code block: a card with the language and a Copy button over the code, which
/// scrolls sideways rather than wrapping, as Desktop's and the Mac's do.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code});
  final MdCode code;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.codeBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.cardStroke),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(children: [
            Expanded(child: Text(code.language ?? '', style: TextStyle(fontSize: 12, color: p.text3))),
            Tooltip(
              message: 'Copy code',
              child: IconButton(
                icon: const Icon(Glyphs.copy, size: 13),
                onPressed: () => Clipboard.setData(ClipboardData(text: code.text)),
              ),
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(code.text, style: TextStyle(fontFamily: monoFont, fontSize: 13, height: 1.5, color: p.text)),
        ),
      ]),
    );
  }
}

/// A table: a header row on a faint fill, rows with hairlines between, columns as wide
/// as their content up to a limit, scrolling sideways when the whole is wider than the
/// column (Desktop's `markdown-table.tsx`).
class _TableView extends StatelessWidget {
  const _TableView({required this.table, required this.base});
  final MdTable table;
  final TextStyle base;

  static const _maxColumn = 320.0;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final columns = table.header.length;
    if (columns == 0) return const SizedBox.shrink();
    TextAlign align(int c) => switch (c < table.alignments.length ? table.alignments[c] : 'none') {
          'center' => TextAlign.center,
          'trailing' => TextAlign.right,
          _ => TextAlign.left,
        };
    Widget cell(List<MdRun> runs, int c) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxColumn),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: RunText(runs: runs, base: base.copyWith(height: 1.4), textAlign: align(c)),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: p.cardStroke), borderRadius: BorderRadius.circular(6)),
        clipBehavior: Clip.antiAlias,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          border: TableBorder(horizontalInside: BorderSide(color: p.divider), verticalInside: BorderSide(color: p.divider)),
          children: [
            TableRow(
              decoration: BoxDecoration(color: p.subtle),
              children: [for (var c = 0; c < columns; c++) cell(table.header[c], c)],
            ),
            for (final row in table.rows)
              TableRow(children: [
                for (var c = 0; c < columns; c++) cell(c < row.length ? row[c] : const [], c),
              ]),
          ],
        ),
      ),
    );
  }
}
