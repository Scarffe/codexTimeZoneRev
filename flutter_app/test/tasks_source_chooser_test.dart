import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/independent_tasks_panel.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/services/tasks.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/tasks_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multi_account_fixture.dart';
import 'tasks_fixture.dart';
import 'tasks_panel_test.dart' show host;

class _CatalogSources extends AccountSourcesController {
  _CatalogSources()
    : super(SyntheticMultiSources(), AccountSourceStore.memory());
  final catalog = <AccountSourceState>[
    AccountSourceState(id: 'current', alias: 'Current account'),
    AccountSourceState(id: 'default', alias: 'Default account'),
    AccountSourceState(id: 'unmanaged-home', alias: 'Unmanaged account'),
    AccountSourceState(id: 'profile-managed', alias: 'Managed account'),
    AccountSourceState(id: 'profile-removing', alias: 'Removing account')
      ..pendingRemoval = true,
  ];
  @override
  List<AccountSourceState> get states => List.unmodifiable(catalog);
}

void main() {
  testWidgets(
    'official chooser is explicit managed-only; preview aliases are independent of monitor selection',
    (tester) async {
      final sources = _CatalogSources()..selectedId = 'profile-managed';
      final backend = TasksBackend();
      final tasks = TasksController(
        TaskService(backend),
        pollInterval: const Duration(days: 1),
      );
      final language = ValueNotifier(AppLanguage.en);
      addTearDown(sources.dispose);
      addTearDown(tasks.dispose);
      addTearDown(language.dispose);
      await tasks.initialize();
      await tester.pumpWidget(
        host(
          IndependentTasksPanel(controller: tasks, sources: sources),
          language,
          DashboardThemeStyle.tech,
        ),
      );
      await tester.pumpAndSettle();
      expect(tasks.sourceId, 'preview-a');
      expect(find.text('Synthetic source A'), findsOneWidget);
      tasks.updateDraft(
        mode: 'official',
        prompt: 'synthetic',
        workspace: 'synthetic-only',
        model: 'synthetic-model',
      );
      await tester.pumpAndSettle();
      expect(
        tasks.sourceId,
        isEmpty,
        reason: 'monitor selection never attributes an official task',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('task-source')));
      await tester.tap(find.byKey(const ValueKey('task-source')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Current account'), findsNothing);
      expect(find.textContaining('Default account'), findsNothing);
      expect(find.textContaining('Unmanaged account'), findsNothing);
      expect(find.textContaining('Removing account'), findsNothing);
      await tester.tap(find.text('Managed account · profile-managed').last);
      await tester.pumpAndSettle();
      expect(tasks.sourceId, 'profile-managed');
      expect(sources.selectedId, 'profile-managed');
      expect(
        backend.calls.where(
          (call) => call == 'task_prepare' || call == 'task_start',
        ),
        isEmpty,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('task-prepare')));
      await tester.tap(find.byKey(const ValueKey('task-prepare')));
      await tester.pumpAndSettle();
      expect(backend.payloads.last['sourceId'], 'profile-managed');
      expect(backend.calls.where((call) => call == 'task_start'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
