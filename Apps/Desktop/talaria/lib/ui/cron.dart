import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../app/app_state.dart';
import '../app/snapshots.dart';
import 'common.dart';
import 'theme.dart';

/// The profile's cron jobs, as the Mac's Cron tab (`CronJobsList`): the jobs soonest
/// next run first, each opening to its recent runs, with Run Now, Pause/Resume,
/// Deliver To, Edit… and Delete… in its menu. New Cron Job opens the editor, which
/// can also start from one of the server's blueprints.
class CronPane extends StatelessWidget {
  const CronPane({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final cron = app.cron;
    final connected = app.connection.state == LinkState.connected;
    final isCurrent = cron.profile != null && cron.profile == app.selectedProfile;
    if (!connected) {
      return _CronNotice(text: 'Connect to see scheduled jobs');
    }
    if (!cron.isAvailable) {
      return _CronNotice(text: "This connection can't read scheduled jobs.");
    }
    if (!isCurrent || (cron.isLoading && cron.jobs.isEmpty)) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: ProgressRing()));
    }
    return ListView(padding: EdgeInsets.zero, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
        child: Row(children: [
          Icon(Glyphs.clock, size: 15, color: p.text2),
          const SizedBox(width: 8),
          Text('Cron Jobs', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.text)),
          const Spacer(),
          Button(
            onPressed: connected ? () => _newJob(context) : null,
            child: const Text('New Cron Job'),
          ),
        ]),
      ),
      if (cron.error case final error?)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Text(error, style: TextStyle(fontSize: 12, color: p.critical)),
        ),
      if (cron.jobs.isEmpty && cron.error == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No cron jobs', style: TextStyle(fontSize: 13, color: p.text)),
            const SizedBox(height: 2),
            Text(
              'Make one with New Cron Job, or ask Hermes in a chat, such as '
              '“every morning at 9, summarize the news”.',
              style: TextStyle(fontSize: 12, color: p.text2, height: 1.3),
            ),
          ]),
        ),
      for (final job in cron.jobs) ...[
        _CronJobRow(app: app, job: job),
        if (app.isCronExpanded(job.id)) ..._runRows(context, job),
      ],
    ]);
  }

  void _newJob(BuildContext context) {
    app.loadCronBlueprints();
    showDialog(context: context, builder: (context) => CronJobEditor(app: app));
  }

  /// The job's recent runs, newest first, set in under it. A run with a session
  /// opens it as a chat; a script-only run shows the start of its output.
  List<Widget> _runRows(BuildContext context, CronJobEntry job) {
    final p = PaletteScope.of(context);
    final cron = app.cron;
    final runs = cron.runs[job.id];
    if (runs == null) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(46, 6, 12, 6),
          child: SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
        ),
      ];
    }
    if (runs.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(46, 6, 12, 6),
          child: Text(cron.runErrors[job.id] ?? 'No runs yet',
              style: TextStyle(fontSize: 12, color: cron.runErrors[job.id] == null ? p.text3 : p.critical)),
        ),
      ];
    }
    return [
      for (final run in runs)
        ListItem(
          selected: false,
          height: 34,
          onPressed: run.entryID == null ? () {} : () => app.openCronRun(run),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(
                relativeTime((run.lastActive ?? run.startedAt) ?? DateTime.now()),
                style: TextStyle(fontSize: 12, color: run.isOutputDocument ? p.text3 : p.text),
              ),
              if (run.isOutputDocument && (run.preview ?? '').trim().isNotEmpty)
                Text(run.preview!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.text3, height: 1.25)),
            ]),
          ),
        ),
    ];
  }
}

class _CronNotice extends StatelessWidget {
  const _CronNotice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(text, style: TextStyle(fontSize: 12, color: p.text2)),
    );
  }
}

/// One job: its chevron, a status dot, the title and the schedule line, and its
/// menu (Run Now, Pause/Resume, Deliver To, Edit…, Delete…).
class _CronJobRow extends StatefulWidget {
  const _CronJobRow({required this.app, required this.job});
  final AppState app;
  final CronJobEntry job;
  @override
  State<_CronJobRow> createState() => _CronJobRowState();
}

class _CronJobRowState extends State<_CronJobRow> {
  final _menu = FlyoutController();
  final _delivery = FlyoutController();

  /// Where the menu showed, so the delivery flyout opens over it.
  Offset _menuPosition = Offset.zero;

  @override
  void dispose() {
    _menu.dispose();
    _delivery.dispose();
    super.dispose();
  }

  /// The delivery targets of a job, as HermesKit lists them: Bot Chat first, then
  /// the server's targets, then any target the job has that neither names.
  List<CronTarget> _targets(AppState app, CronJobEntry job) => [
        const CronTarget(id: 'bot-chat', name: 'Bot Chat'),
        ...app.cron.targets.where((t) => t.id != 'bot-chat'),
        for (final id in job.deliver)
          if (id != 'bot-chat' && !app.cron.targets.any((t) => t.id == id)) CronTarget(id: id, name: id),
      ];

  void _showMenu(Offset position) {
    final app = widget.app;
    final job = widget.job;
    final canChange = app.connection.state == LinkState.connected;
    final isRunning = app.cron.triggering.contains(job.id);
    _menuPosition = position;
    _menu.showFlyout(
      position: position,
      barrierColor: const Color(0x00000000),
      builder: (context) => MenuFlyout(items: [
        MenuFlyoutItem(
          leading: Icon(isRunning ? Glyphs.clock : Glyphs.send),
          text: Text(isRunning ? 'Running…' : 'Run Now'),
          onPressed: !canChange || isRunning ? null : () => app.triggerCronJob(job.id),
        ),
        MenuFlyoutItem(
          leading: Icon(job.isPaused ? Glyphs.send : Glyphs.stop),
          text: Text(job.isPaused ? 'Resume' : 'Pause'),
          onPressed: canChange ? () => job.isPaused ? app.resumeCronJob(job.id) : app.pauseCronJob(job.id) : null,
        ),
        // No submenus in a WinUI menu: Deliver To opens its own flyout once the
        // menu has closed.
        MenuFlyoutItem(
          leading: const Icon(Glyphs.send),
          text: const Text('Deliver To…'),
          onPressed: canChange
              ? () => WidgetsBinding.instance.addPostFrameCallback((_) => _showDelivery())
              : null,
        ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(Glyphs.editPage),
          text: const Text('Edit…'),
          onPressed: canChange
              ? () => WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      app.loadCronBlueprints();
                      showDialog(context: context, builder: (context) => CronJobEditor(app: app, job: job));
                    }
                  })
              : null,
        ),
        MenuFlyoutItemBuilder(builder: (context) {
          final red = FluentTheme.of(context).brightness == Brightness.dark
              ? const Color(0xFFFF99A4)
              : const Color(0xFFC42B1C);
          return MenuFlyoutItem(
            leading: Icon(Glyphs.delete, color: red),
            text: Text('Delete…', style: TextStyle(color: red)),
            onPressed: canChange
                ? () => WidgetsBinding.instance.addPostFrameCallback((_) => _delete())
                : null,
          ).build(context);
        }),
      ]),
    );
  }

  /// The delivery flyout, with each target checked as the job has it: toggling one
  /// sets the whole list, keeping the last target on.
  void _showDelivery() {
    final app = widget.app;
    final job = widget.job;
    final canChange = app.connection.state == LinkState.connected;
    final targets = _targets(app, job);
    _delivery.showFlyout(
      position: _menuPosition,
      barrierColor: const Color(0x00000000),
      builder: (context) => MenuFlyout(
        constraints: const BoxConstraints(minWidth: 220),
        items: [
          for (final target in targets)
            MenuFlyoutItemBuilder(
              builder: (context) {
                final theme = FluentTheme.of(context);
                final checked = job.deliver.contains(target.id);
                return MenuFlyoutItem(
                  leading: checked
                      ? Icon(Glyphs.checkMark, size: 13, color: theme.accentColor.normal)
                      : const SizedBox(width: 13),
                  text: Text(target.homeTargetSet ? target.name : '${target.name} (no home channel)'),
                  onPressed: canChange
                      ? () {
                          final next = _toggled(job, target.id);
                          if (next.join(',') != job.deliver.join(',')) app.setCronDelivery(job.id, next);
                        }
                      : null,
                ).build(context);
              },
            ),
        ],
      ),
    );
  }

  /// The job's targets with [target] toggled; the last target stays on.
  List<String> _toggled(CronJobEntry job, String target) {
    final has = job.deliver.contains(target);
    final without = job.deliver.where((t) => t != target).toList();
    return has && without.isEmpty ? job.deliver : (has ? without : [...job.deliver, target]);
  }

  Future<void> _delete() async {
    final app = widget.app;
    final job = widget.job;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Delete ${job.title}?'),
        content: const Text("The job is removed from Hermes and won't run again."),
        actions: [
          Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context, false)),
          Button(child: const Text('Delete'), onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) app.deleteCronJob(job.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final app = widget.app;
    final job = widget.job;
    final expanded = app.isCronExpanded(job.id);
    final isRunning = app.cron.triggering.contains(job.id);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
        child: HoverButton(
          onPressed: () => app.toggleCronRuns(job.id),
          builder: (context, states) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: states.isHovered ? p.subtle : const Color(0x00000000),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            Icon(expanded ? Glyphs.chevronDown : Glyphs.chevronRight, size: 10, color: p.text3),
            const SizedBox(width: 6),
            _JobDot(job: job, isRunning: isRunning),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(job.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: p.text)),
                const SizedBox(height: 1),
                Text(_detailLine(job, isRunning),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: job.needsAttention ? p.critical : p.text2)),
              ]),
            ),
            FlyoutTarget(
              controller: _menu,
              child: IconAction(Glyphs.more, size: 13, tooltip: 'More', onPressed: () {
                final box = context.findRenderObject() as RenderBox;
                _showMenu(box.localToGlobal(Offset.zero) + Offset(0, box.size.height));
              }),
            ),
          ]),
        ),
        ),
      ),
    );
  }

  /// The line under the title: the schedule, then the next run ("in 2 hours"),
  /// the overdue line, the pause reason, or a failure.
  String _detailLine(CronJobEntry job, bool isRunning) {
    final parts = <String>[];
    if (isRunning) parts.add('Running now');
    if (job.isPaused) {
      parts.add(job.pausedReason ?? 'Paused');
    } else if (job.overdueSince case final since?) {
      parts.add('Overdue since ${_clock(since)}');
    } else if (job.nextRunAt case final next?) {
      parts.add('Next ${relativeTime(next)}');
    } else if (job.isScriptOnly) {
      parts.add('Script');
    }
    if (job.lastError case final error?) parts.add(error);
    if (job.lastDeliveryError case final delivery?) parts.add(delivery);
    return parts.join(' · ');
  }

  static String _clock(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// The job's dot: the state's colour, pulsing while it runs now.
class _JobDot extends StatelessWidget {
  const _JobDot({required this.job, this.isRunning = false});
  final CronJobEntry job;
  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final color = job.needsAttention || job.lastError != null
        ? p.critical
        : job.isPaused
            ? p.text3
            : isRunning || job.state == 'running'
                ? p.success
                : p.accent;
    return Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

/// New and Edit Cron Job, as a dialog (the Mac's `CronJobEditor` sheet): a blank
/// form, one started from a blueprint's blanks, or an existing job's.
class CronJobEditor extends StatefulWidget {
  const CronJobEditor({super.key, required this.app, this.job});
  final AppState app;

  /// The job being edited, or null for a new one.
  final CronJobEntry? job;

  @override
  State<CronJobEditor> createState() => _CronJobEditorState();
}

class _CronJobEditorState extends State<CronJobEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.job?.name ?? '');
  late final TextEditingController _prompt = TextEditingController(
      text: widget.job != null && widget.job!.isScriptOnly ? '' : widget.job?.prompt ?? '');

  /// The schedule the form holds, parsed from the job's expression when editing.
  late String _frequency = _initialFrequency ?? 'daily';
  late final Map<String, int> _initialTimeFields = _initialTime ?? const {'hour': 9, 'minute': 0};
  late int _hour = _initialTimeFields['hour'] ?? 9;
  late int _minute = _initialTimeFields['minute'] ?? 0;
  late int _weekday = _initialWeekday;
  late int _dayOfMonth = _initialDayOfMonth;
  late final TextEditingController _custom = TextEditingController(text: _initialCustom);

  /// The blueprint started from; null is the form itself.
  String? _blueprintKey;
  final Map<String, TextEditingController> _blueprintValues = {};

  /// The targets to deliver to, from the job's own when editing.
  late final Set<String> _deliver = {...?widget.job?.deliver};

  /// The picked model, as provider\u0000model, or null for the profile's default.
  String? _model;
  List<ModelProvider> _models = const [];
  bool _isSaving = false;

  static const frequencies = {
    'daily': 'Every day',
    'weekdays': 'Weekdays',
    'weekly': 'Every week',
    'monthly': 'Every month',
    'hourly': 'Every hour',
    'every15Minutes': 'Every 15 minutes',
    'custom': 'Custom',
  };

  String? get _initialFrequency {
    final parts = _initialExpression.split(' ');
    if (parts.length == 5) {
      final minute = parts[0], hour = parts[1], day = parts[2], weekday = parts[4];
      if (day == '*' && weekday == '*') {
        if (minute == '*/15') return 'every15Minutes';
        if (hour == '*') return 'hourly';
        return 'daily';
      }
      if (day == '*' && weekday == '1-5') return 'weekdays';
      if (day == '*' && int.tryParse(weekday) != null) return 'weekly';
      if (weekday == '*' && int.tryParse(day) != null) return 'monthly';
    }
    return 'custom';
  }

  String get _initialExpression {
    final expression = widget.job?.scheduleExpression ?? '';
    if (expression.contains(' ')) return expression;
    // A display line ("0 9 * * *") or something else: leave the fields at their defaults.
    return '';
  }

  Map<String, int>? get _initialTime {
    final parts = _initialExpression.split(' ');
    if (parts.length == 5 && parts[1] != '*') {
      return {'hour': int.tryParse(parts[1]) ?? 9, 'minute': int.tryParse(parts[0]) ?? 0};
    }
    return null;
  }

  int get _initialWeekday {
    final parts = _initialExpression.split(' ');
    if (parts.length == 5) {
      if (int.tryParse(parts[4]) case final day?) return day;
    }
    return 1;
  }

  int get _initialDayOfMonth {
    final parts = _initialExpression.split(' ');
    if (parts.length == 5) {
      if (int.tryParse(parts[2]) case final day?) return day;
    }
    return 1;
  }

  String get _initialCustom => _initialFrequency == 'custom' ? _initialExpression : '';

  @override
  void initState() {
    super.initState();
    if (widget.job?.provider case final provider?) {
      if (widget.job?.model case final model?) _model = '$provider\u0000$model';
    }
    unawaited(_loadModels());
  }

  Future<void> _loadModels() async {
    final models = await widget.app.cronModelCatalog();
    if (mounted) setState(() => _models = models);
  }

  Map<String, Object?> get _draft => {
        'name': _name.text,
        'prompt': _prompt.text,
        'schedule': {
          'frequency': _frequency,
          'hour': _hour,
          'minute': _minute,
          'weekday': _weekday,
          'dayOfMonth': _dayOfMonth,
          'custom': _custom.text,
        },
        'deliver': _deliver.join(','),
        if (_model case final key?)
          ...{
            'provider': key.split('\u0000')[0],
            'model': key.split('\u0000')[1],
          }
        else
          'provider': null,
      };

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _custom.dispose();
    for (final controller in _blueprintValues.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _canSave => _blueprintKey != null || _prompt.text.trim().isNotEmpty;

  Future<void> _save() async {
    final app = widget.app;
    setState(() => _isSaving = true);
    try {
      if (_blueprintKey case final key?) {
        await app.instantiateCronBlueprint(key, {
          for (final entry in _blueprintValues.entries) entry.key: entry.value.text,
          if (_deliver.contains('bot-chat')) 'deliver': _deliver.join(','),
        });
      } else if (widget.job case final job?) {
        await app.saveCronJob(job.id, _draft);
      } else {
        await app.createCronJob(_draft);
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final app = widget.app;
    final blueprint = _blueprintKey == null
        ? null
        : app.cron.blueprints.where((b) => b.key == _blueprintKey).firstOrNull;
    return ContentDialog(
      title: Text(widget.job == null ? 'New Cron Job' : 'Edit Cron Job'),
      constraints: const BoxConstraints(maxWidth: 460),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (widget.job == null && app.cron.blueprints.isNotEmpty) ...[
            _label('Start From'),
            ComboBox<String>(
              value: _blueprintKey ?? '',
              items: [
                const ComboBoxItem(value: '', child: Text('A blank job')),
                for (final b in app.cron.blueprints) ComboBoxItem(value: b.key, child: Text(b.title)),
              ],
              onChanged: (key) => setState(() {
                _blueprintKey = key == '' || key == null ? null : key;
                for (final controller in _blueprintValues.values) {
                  controller.dispose();
                }
                _blueprintValues.clear();
                if (_blueprintKey case final pickedKey?) {
                  final picked = app.cron.blueprints.firstWhere((b) => b.key == pickedKey);
                  // Each blank starts at its default, as the Mac's dialog fills them.
                  for (final field in picked.fields.where((f) => !f.isDeliver)) {
                    _blueprintValues[field.name] = TextEditingController(
                      text: field.defaultValue ??
                          switch (field.kind) {
                            'enum' => field.options.isNotEmpty ? field.options.first : '',
                            'time' => '09:00',
                            'weekdays' => 'Monday',
                            _ => '',
                          },
                    );
                  }
                  // The deliver blank starts its options checked.
                  for (final field in picked.fields.where((f) => f.isDeliver)) {
                    _deliver.addAll(field.options);
                  }
                }
              }),
            ),
            const SizedBox(height: 14),
          ],
          if (blueprint != null) ...[
            Text(blueprint.description, style: TextStyle(fontSize: 12, color: p.text2, height: 1.3)),
            const SizedBox(height: 10),
            for (final field in blueprint.fields) ..._blueprintField(app, field),
          ] else ...[
            _label('Name (optional)'),
            TextBox(controller: _name, placeholder: 'Morning brief'),
            const SizedBox(height: 12),
            _label('Prompt'),
            TextBox(
              controller: _prompt,
              placeholder: 'What Hermes runs on the schedule',
              maxLines: 3,
              keyboardType: TextInputType.multiline,
            ),
            const SizedBox(height: 12),
            _label('Repeat'),
            ComboBox<String>(
              value: _frequency,
              items: [
                for (final entry in frequencies.entries) ComboBoxItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(() => _frequency = value ?? 'daily'),
            ),
            const SizedBox(height: 12),
            if (const ['daily', 'weekdays', 'weekly', 'monthly'].contains(_frequency)) ...[
              Row(children: [
                Text('At', style: TextStyle(fontSize: 12, color: p.text2)),
                const SizedBox(width: 10),
                TimePicker(
                  selected: DateTime(2000, 1, 1, _hour, _minute),
                  onChanged: (time) => setState(() {
                    _hour = time.hour;
                    _minute = time.minute;
                  }),
                ),
              ]),
              const SizedBox(height: 12),
            ],
            if (_frequency == 'weekly') ...[
              _label('Day of the week'),
              ComboBox<int>(
                value: _weekday,
                items: [
                  for (final (i, name) in const [
                    'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
                  ].indexed)
                    ComboBoxItem(value: i, child: Text(name)),
                ],
                onChanged: (value) => setState(() => _weekday = value ?? 1),
              ),
              const SizedBox(height: 12),
            ],
            if (_frequency == 'monthly') ...[
              _label('Day of the month'),
              ComboBox<int>(
                value: _dayOfMonth,
                items: [for (var d = 1; d <= 31; d++) ComboBoxItem(value: d, child: Text('$d'))],
                onChanged: (value) => setState(() => _dayOfMonth = value ?? 1),
              ),
              const SizedBox(height: 12),
            ],
            if (_frequency == 'custom') ...[
              _label('Schedule (cron)'),
              TextBox(controller: _custom, placeholder: '0 9 * * 1-5'),
              const SizedBox(height: 12),
            ],
          ],
          _label('Deliver To'),
          for (final target in _deliveryOptions(app))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                ToggleSwitch(
                  checked: _deliver.contains(target.id),
                  onChanged: (on) => setState(() => on ? _deliver.add(target.id) : _deliver.remove(target.id)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(target.homeTargetSet ? target.name : '${target.name} (no home channel)')),
              ]),
            ),
          if (widget.job == null || !widget.job!.isScriptOnly) ...[
            const SizedBox(height: 12),
            _label('Model'),
            if (_models.isEmpty)
              Text('The profile\'s default', style: TextStyle(fontSize: 12, color: p.text3))
            else
              ComboBox<String>(
                value: _model ?? '',
                items: [
                  const ComboBoxItem(value: '', child: Text("The profile's default")),
                  for (final provider in _models)
                    for (final model in provider.models)
                      ComboBoxItem(
                          value: '${provider.slug}\u0000${model.model}', child: Text('${model.label} · ${provider.name}')),
                ],
                onChanged: (key) => setState(() => _model = key == '' ? null : key),
              ),
          ],
        ]),
      ),
      actions: [
        Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context)),
        FilledButton(
          onPressed: _isSaving || !_canSave ? null : _save,
          child: _isSaving
              ? const SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  /// The delivery toggles' rows: Bot Chat first, then the server's targets.
  List<CronTarget> _deliveryOptions(AppState app) {
    return [
      const CronTarget(id: 'bot-chat', name: 'Bot Chat'),
      ...app.cron.targets.where((t) => t.id != 'bot-chat'),
    ];
  }

  /// One of the blueprint's blanks, as the Mac's editor fills them: a text field,
  /// a picker of options, a time, or a day of the week.
  List<Widget> _blueprintField(AppState app, CronBlueprintField field) {
    if (field.isDeliver) return const [];
    return [
      _label(field.label + (field.isOptional ? ' (optional)' : '')),
      if (field.kind == 'enum' && field.options.isNotEmpty)
        ComboBox<String>(
          value: _blueprintValue(field, field.options.first),
          items: [for (final option in field.options) ComboBoxItem(value: option, child: Text(option))],
          onChanged: (value) => setState(() => _blueprintValues[field.name]?.text = value ?? ''),
        )
      else if (field.kind == 'time')
        TimePicker(
          selected: DateTime(2000, 1, 1, 9),
          onChanged: (time) => setState(() => _blueprintValues[field.name]?.text =
              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'),
        )
      else if (field.kind == 'weekdays')
        ComboBox<String>(
          value: _blueprintValue(field, 'Monday'),
          items: const [
            ComboBoxItem(value: 'Monday', child: Text('Monday')),
            ComboBoxItem(value: 'Tuesday', child: Text('Tuesday')),
            ComboBoxItem(value: 'Wednesday', child: Text('Wednesday')),
            ComboBoxItem(value: 'Thursday', child: Text('Thursday')),
            ComboBoxItem(value: 'Friday', child: Text('Friday')),
            ComboBoxItem(value: 'Saturday', child: Text('Saturday')),
            ComboBoxItem(value: 'Sunday', child: Text('Sunday')),
          ],
          onChanged: (value) => setState(() => _blueprintValues[field.name]?.text = value ?? ''),
        )
      else
        TextBox(
          controller: _blueprintValues.putIfAbsent(field.name, () => TextEditingController(text: field.defaultValue ?? '')),
          placeholder: field.help,
        ),
      const SizedBox(height: 12),
    ];
  }

  String _blueprintValue(CronBlueprintField field, String fallback) {
    final controller = _blueprintValues[field.name];
    final text = controller?.text ?? '';
    return field.options.contains(text) ? text : fallback;
  }

  Widget _label(String text) {
    final p = PaletteScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.text2)),
    );
  }
}
