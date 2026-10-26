import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/tasks.dart';
import '../state/account_sources_controller.dart';
import '../state/tasks_controller.dart';
import 'monitor_information.dart';

class IndependentTasksPanel extends StatefulWidget {
  const IndependentTasksPanel({
    super.key,
    required this.controller,
    this.sources,
    this.chooseWorkspace,
  });
  final TasksController controller;
  final AccountSourcesController? sources;
  final Future<String?> Function()? chooseWorkspace;
  @override
  State<IndependentTasksPanel> createState() => _IndependentTasksPanelState();
}

class _IndependentTasksPanelState extends State<IndependentTasksPanel> {
  final _workspace = TextEditingController(),
      _model = TextEditingController(),
      _prompt = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _sync();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(IndependentTasksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _sync();
      unawaited(widget.controller.initialize());
    }
  }

  void _sync() {
    void set(TextEditingController target, String value) {
      if (target.text != value) {
        target.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    }

    set(_workspace, widget.controller.workspace);
    set(_model, widget.controller.model);
    set(_prompt, widget.controller.prompt);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _workspace.dispose();
    _model.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Widget _button(
    BuildContext context,
    String key,
    String text,
    VoidCallback? action, {
    bool outline = false,
  }) => FButton(
    key: ValueKey(key),
    mainAxisSize: MainAxisSize.min,
    variant: outline ? FButtonVariant.outline : FButtonVariant.primary,
    onPress: action,
    child: Flexible(child: Text(AppCopy.of(context).text(text))),
  );
  Future<void> _choose() async {
    try {
      final path = await (widget.chooseWorkspace?.call() ?? getDirectoryPath());
      if (mounted && path != null) {
        widget.controller.updateDraft(workspace: path);
      }
    } catch (_) {
      if (mounted) {
        widget.controller.lastError = 'invalid_request';
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      if (widget.sources != null) widget.sources!,
    ]),
    builder: (context, _) {
      final c = widget.controller, copy = AppCopy.of(context);
      final managed =
          widget.sources?.states
              .where(
                (s) =>
                    !s.isCurrent &&
                    !s.pendingRemoval &&
                    RegExp(r'^profile-[a-zA-Z0-9-]+$').hasMatch(s.id),
              )
              .toList() ??
          [];
      final sourceItems = c.mode == 'offline_preview'
          ? <String, String>{
              copy.text('tasks.previewA'): 'preview-a',
              copy.text('tasks.previewB'): 'preview-b',
            }
          : <String, String>{
              for (final s in managed) '${s.alias} · ${s.id}': s.id,
            };
      final validSource = sourceItems.values.contains(c.sourceId);
      final selected = c.tasks
          .where(
            (t) =>
                c.filter == 'all' ||
                (c.filter == 'active' ? t.active : t.terminal),
          )
          .toList();
      return SingleChildScrollView(
        key: const PageStorageKey('independent-tasks-scroll'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              copy.text('tasks.title'),
              style: context.theme.typography.display.sm,
            ),
            Text(copy.text('tasks.subtitle')),
            const SizedBox(height: 12),
            FCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FSelect<String>(
                      key: const ValueKey('task-mode'),
                      label: Text(copy.text('tasks.mode')),
                      items: {
                        copy.text('tasks.mode.offline_preview'):
                            'offline_preview',
                        if (c.officialEnabled)
                          copy.text('tasks.mode.official'): 'official',
                      },
                      control: FSelectControl.lifted(
                        value: c.mode,
                        onChange: (v) {
                          if (v != null) c.updateDraft(mode: v);
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      copy.text(
                        c.mode == 'offline_preview'
                            ? 'tasks.previewNotice'
                            : 'tasks.officialNotice',
                      ),
                    ),
                    const SizedBox(height: 8),
                    FSelect<String>(
                      key: const ValueKey('task-source'),
                      label: Text(copy.text('tasks.source')),
                      items: sourceItems,
                      enabled: sourceItems.isNotEmpty,
                      control: FSelectControl.lifted(
                        value: validSource ? c.sourceId : null,
                        onChange: (v) {
                          if (v != null) c.updateDraft(sourceId: v);
                        },
                      ),
                    ),
                    if (c.mode == 'official' && managed.isEmpty)
                      Text(copy.text('tasks.noSources')),
                    const SizedBox(height: 8),
                    FTextField(
                      key: const ValueKey('task-workspace'),
                      label: Text(copy.text('tasks.workspace')),
                      control: FTextFieldControl.managed(
                        controller: _workspace,
                        onChange: (v) => c.updateDraft(workspace: v.text),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _button(
                        context,
                        'task-choose-workspace',
                        'tasks.chooseWorkspace',
                        _choose,
                        outline: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FTextField(
                      key: const ValueKey('task-model'),
                      label: Text(copy.text('tasks.model')),
                      control: FTextFieldControl.managed(
                        controller: _model,
                        onChange: (v) => c.updateDraft(model: v.text),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FTextField(
                      key: const ValueKey('task-prompt'),
                      label: Text(copy.text('tasks.prompt')),
                      minLines: 3,
                      maxLines: 6,
                      control: FTextFieldControl.managed(
                        controller: _prompt,
                        onChange: (v) => c.updateDraft(prompt: v.text),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FSelect<String>(
                      key: const ValueKey('task-sandbox'),
                      label: Text(copy.text('tasks.sandbox')),
                      items: {
                        for (final s in taskSandboxes)
                          copy.text('tasks.sandbox.$s'): s,
                      },
                      control: FSelectControl.lifted(
                        value: c.sandbox,
                        onChange: (v) {
                          if (v != null) c.updateDraft(sandbox: v);
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _button(
                        context,
                        'task-prepare',
                        c.preparing ? 'tasks.preparing' : 'tasks.prepare',
                        c.canPrepare && validSource
                            ? () => unawaited(c.prepare())
                            : null,
                      ),
                    ),
                    if (c.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          copy.text(
                            'tasks.error.${taskErrorKind(c.lastError)}',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FSelect<String>(
              key: const ValueKey('task-filter'),
              label: Text(copy.text('tasks.filter')),
              items: {
                for (final f in ['all', 'active', 'terminal'])
                  copy.text('tasks.filter.$f'): f,
              },
              control: FSelectControl.lifted(
                value: c.filter,
                onChange: (v) {
                  if (v != null) c.setFilter(v);
                },
              ),
            ),
            const SizedBox(height: 12),
            if (selected.isEmpty) Text(copy.text('tasks.empty')),
            for (final task in selected)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _card(context, task),
              ),
          ],
        ),
      );
    },
  );
  Widget _card(BuildContext context, TaskSnapshot task) {
    final copy = AppCopy.of(context), c = widget.controller;
    return FCard(
      key: ValueKey('task-card-${task.taskId}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${copy.text('tasks.state.${task.state}')} · ${copy.text('tasks.mode.${task.mode}')}',
              style: context.theme.typography.body.lg,
            ),
            Text('${task.sourceId} · ${task.workspace}'),
            Text(
              '${task.model} · ${copy.text('tasks.sandbox.${task.sandbox}')}',
            ),
            if (task.restored) Text(copy.text('tasks.restored')),
            if (task.cleanupPending) Text(copy.text('tasks.cleanupPending')),
            if (task.errorKind != null)
              Text(copy.text('tasks.error.${taskErrorKind(task.errorKind)}')),
            if (task.observedIdentity?.isNotEmpty == true)
              Text(
                copy.text(
                  'tasks.identityObservation',
                  args: {
                    'value': task.observedIdentity!.values
                        .whereType<String>()
                        .join(' · '),
                  },
                ),
              ),
            if (task.usage != null)
              Text(
                copy.text(
                  'tasks.usage',
                  args: {
                    'input': task.usage!.inputTokens ?? '—',
                    'output': task.usage!.outputTokens ?? '—',
                    'reasoning': task.usage!.reasoningTokens ?? '—',
                  },
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (task.state == 'prepared' && !task.restored)
                  _button(
                    context,
                    'task-start-${task.taskId}',
                    'tasks.start',
                    c.canStart(task) ? () => unawaited(c.start(task)) : null,
                  ),
                if (!task.terminal || task.cleanupPending)
                  _button(
                    context,
                    'task-cancel-${task.taskId}',
                    'tasks.cancel',
                    c.canCancel(task) ? () => unawaited(c.cancel(task)) : null,
                    outline: true,
                  ),
                _button(
                  context,
                  'task-clear-${task.taskId}',
                  'tasks.clear',
                  c.canClear(task) ? () => unawaited(c.clear(task)) : null,
                  outline: true,
                ),
                for (final approval in task.approvals)
                  _button(
                    context,
                    'task-approval-${approval.approvalId}',
                    'tasks.approval',
                    c.owns(task)
                        ? () => _approval(context, task, approval)
                        : null,
                    outline: true,
                  ),
                for (final input in task.inputRequests)
                  _button(
                    context,
                    'task-input-${input.requestId}',
                    'tasks.input',
                    c.owns(task) ? () => _input(context, task, input) : null,
                    outline: true,
                  ),
              ],
            ),
            if (task.output.isNotEmpty || task.outputTruncated) ...[
              const SizedBox(height: 10),
              Text(copy.text('tasks.output')),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: SelectableText(task.output),
                ),
              ),
              if (task.outputTruncated)
                Text(copy.text('tasks.outputTruncated')),
            ],
          ],
        ),
      ),
    );
  }

  void _approval(
    BuildContext context,
    TaskSnapshot task,
    TaskApproval approval,
  ) {
    unawaited(
      showMonitorInformation(
        context,
        title: '',
        titleKey: 'tasks.approvalTitle',
        builder: (context) => ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final c = widget.controller;
            final current = c.tasks
                .where((t) => t.sameIdentity(task))
                .firstOrNull;
            final available =
                current?.approvals
                    .where((a) => a.approvalId == approval.approvalId)
                    .firstOrNull ??
                approval;
            final pending =
                current?.approvals.any(
                      (a) => a.approvalId == approval.approvalId,
                    ) ==
                    true &&
                current != null &&
                c.owns(current) &&
                !c.isBusy(current);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${task.sourceId} · ${task.workspace}'),
                Text(approval.summary),
                if (approval.command != null) SelectableText(approval.command!),
                if (approval.cwd != null) Text(approval.cwd!),
                for (final file in approval.files) Text(file),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final decision in available.decisions)
                      _button(
                        context,
                        'task-decision-$decision',
                        const {
                          'accept': 'tasks.accept',
                          'decline': 'tasks.decline',
                          'cancel': 'tasks.cancelApproval',
                        }[decision]!,
                        pending
                            ? () => unawaited(
                                c.approve(
                                  current,
                                  approval.approvalId,
                                  decision,
                                ),
                              )
                            : null,
                        outline: true,
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _input(BuildContext context, TaskSnapshot task, TaskInputRequest input) {
    unawaited(
      showMonitorInformation(
        context,
        title: '',
        titleKey: 'tasks.inputTitle',
        builder: (context) => _TaskInputForm(
          controller: widget.controller,
          task: task,
          request: input,
        ),
      ),
    );
  }
}

class _TaskInputForm extends StatefulWidget {
  const _TaskInputForm({
    required this.controller,
    required this.task,
    required this.request,
  });
  final TasksController controller;
  final TaskSnapshot task;
  final TaskInputRequest request;
  @override
  State<_TaskInputForm> createState() => _TaskInputFormState();
}

class _TaskInputFormState extends State<_TaskInputForm> {
  final _answers = <String, String>{};
  final _other = <String, String>{};
  final _editors = <String, TextEditingController>{};
  @override
  void dispose() {
    for (final editor in _editors.values) {
      editor.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final copy = AppCopy.of(context), c = widget.controller;
      final current = c.tasks
          .where((t) => t.sameIdentity(widget.task))
          .firstOrNull;
      final pending =
          current?.inputRequests.any(
                (r) => r.requestId == widget.request.requestId,
              ) ==
              true &&
          current != null &&
          c.owns(current) &&
          !c.isBusy(current);
      final complete = widget.request.questions.every(
        (q) => (_answers[q.id] ?? _other[q.id] ?? '').trim().isNotEmpty,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${widget.task.sourceId} · ${widget.task.workspace}'),
          for (final question in widget.request.questions) ...[
            const SizedBox(height: 12),
            Text(question.header),
            Text(question.question),
            if (question.options.isNotEmpty)
              FSelect<String>(
                key: ValueKey('task-question-${question.id}'),
                items: {
                  for (final option in question.options)
                    option.label: option.label,
                },
                control: FSelectControl.lifted(
                  value: _answers[question.id],
                  onChange: (v) => setState(() {
                    if (v != null) {
                      _answers[question.id] = v;
                      _other.remove(question.id);
                    }
                  }),
                ),
              ),
            for (final option in question.options)
              Text('${option.label} · ${option.description}'),
            if (question.options.isEmpty || question.isOther)
              FTextField(
                key: ValueKey('task-answer-${question.id}'),
                obscureText: question.isSecret,
                label: Text(
                  copy.text(
                    question.options.isEmpty
                        ? 'tasks.answer'
                        : 'tasks.otherAnswer',
                  ),
                ),
                control: FTextFieldControl.managed(
                  controller: _editors.putIfAbsent(
                    question.id,
                    () => TextEditingController(),
                  ),
                  onChange: (v) => setState(() {
                    _other[question.id] = v.text;
                    _answers.remove(question.id);
                  }),
                ),
              ),
          ],
          const SizedBox(height: 12),
          FButton(
            key: const ValueKey('task-submit-answers'),
            onPress: pending && complete
                ? () => unawaited(
                    c.answer(current, widget.request.requestId, {
                      for (final q in widget.request.questions)
                        q.id: [_answers[q.id] ?? _other[q.id] ?? ''],
                    }),
                  )
                : null,
            child: Flexible(child: Text(copy.text('tasks.sendAnswers'))),
          ),
        ],
      );
    },
  );
}
