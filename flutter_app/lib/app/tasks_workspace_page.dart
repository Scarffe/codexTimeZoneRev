import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/session_attention.dart';
import '../state/account_sources_controller.dart';
import '../state/session_attention_controller.dart';
import '../state/tasks_controller.dart';
import 'independent_tasks_panel.dart';
import 'session_attention_page.dart';

/// Local observations and app-owned tasks keep distinct owners and identities.
class TasksWorkspacePage extends StatefulWidget {
  const TasksWorkspacePage({
    super.key,
    required this.attention,
    required this.tasks,
    required this.onOpenNotice,
    this.sources,
  });
  final SessionAttentionController attention;
  final TasksController tasks;
  final AccountSourcesController? sources;
  final ValueChanged<SessionAttentionNotice> onOpenNotice;
  @override
  State<TasksWorkspacePage> createState() => _TasksWorkspacePageState();
}

class _TasksWorkspacePageState extends State<TasksWorkspacePage> {
  bool _tasks = false;
  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FButton(
              key: const ValueKey('inbox-attention-tab'),
              mainAxisSize: MainAxisSize.min,
              variant: _tasks ? FButtonVariant.outline : FButtonVariant.primary,
              onPress: () => setState(() => _tasks = false),
              child: Text(copy.text('tasks.attentionTab')),
            ),
            FButton(
              key: const ValueKey('inbox-tasks-tab'),
              mainAxisSize: MainAxisSize.min,
              variant: _tasks ? FButtonVariant.primary : FButtonVariant.outline,
              onPress: () => setState(() => _tasks = true),
              child: Text(copy.text('tasks.tab')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _tasks
              ? IndependentTasksPanel(
                  controller: widget.tasks,
                  sources: widget.sources,
                )
              : SessionAttentionPage(
                  controller: widget.attention,
                  onOpenNotice: widget.onOpenNotice,
                ),
        ),
      ],
    );
  }
}
