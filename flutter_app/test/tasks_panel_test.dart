import 'package:codex_timezone/app/independent_tasks_panel.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/l10n/app_copy.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/tasks.dart';
import 'package:codex_timezone/state/tasks_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'tasks_fixture.dart';

Widget host(
  Widget child,
  ValueNotifier<AppLanguage> language,
  DashboardThemeStyle style,
) => WidgetsApp(
  color: const Color(0xff000000),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  builder: (_, route) => ValueListenableBuilder<AppLanguage>(
    valueListenable: language,
    builder: (_, value, _) => FTheme(
      data: launcherTheme(false, style: style, language: value),
      child: AppCopyScope(
        language: value,
        child: FToaster(
          child: FTooltipGroup(
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14),
              child: route!,
            ),
          ),
        ),
      ),
    ),
  ),
  onGenerateRoute: (_) =>
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => child),
);

void main() {
  testWidgets(
    'approval and secret input remain task-bound across locale/theme redraw',
    (tester) async {
      final b = TasksBackend();
      final c = TasksController(
        TaskService(b),
        pollInterval: const Duration(days: 1),
      );
      final language = ValueNotifier(AppLanguage.zh);
      addTearDown(c.dispose);
      addTearDown(language.dispose);
      await c.initialize();
      c.updateDraft(prompt: 'p');
      final task = (await c.prepare())!;
      await c.start(task);
      b.tasks[task.taskId]!.addAll({
        'state': 'awaiting_approval',
        'approvals': [
          {
            'approvalId': 'approval-1',
            'kind': 'command',
            'summary': 'raw command review',
            'command': 'echo synthetic',
            'cwd': null,
            'files': <String>[],
            'decisions': ['decline', 'cancel'],
          },
        ],
      });
      await c.poll();
      final panel = IndependentTasksPanel(controller: c);
      await tester.pumpWidget(host(panel, language, DashboardThemeStyle.soft));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-approval-approval-1')),
      );
      await tester.tap(find.byKey(const ValueKey('task-approval-approval-1')));
      await tester.pumpAndSettle();
      language.value = AppLanguage.en;
      await tester.pumpAndSettle();
      expect(find.text('Task approval'), findsOneWidget);
      expect(find.byKey(const ValueKey('task-decision-accept')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('task-decision-decline')));
      await tester.pumpAndSettle();
      expect(b.payloads.last['decision'], 'decline');
      await tester.tap(find.byKey(const ValueKey('monitor-information-close')));
      await tester.pumpAndSettle();
      b.tasks[task.taskId]!.addAll({
        'state': 'awaiting_input',
        'inputRequests': [
          {
            'requestId': 'input-1',
            'questions': [
              {
                'id': 'secret',
                'header': 'Raw header',
                'question': 'Raw question',
                'isOther': true,
                'isSecret': true,
                'options': <dynamic>[],
              },
            ],
          },
        ],
      });
      await c.poll();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-input-input-1')),
      );
      await tester.tap(find.byKey(const ValueKey('task-input-input-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('task-answer-secret')),
          matching: find.byType(EditableText),
        ),
        'one private answer',
      );
      language.value = AppLanguage.zh;
      await tester.pumpWidget(
        host(panel, language, DashboardThemeStyle.graphite),
      );
      await tester.pumpAndSettle();
      final editor = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('task-answer-secret')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editor.controller.text, 'one private answer');
      expect(editor.obscureText, true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-submit-answers')),
      );
      await tester.tap(find.byKey(const ValueKey('task-submit-answers')));
      await tester.pumpAndSettle();
      expect(b.payloads.last['requestId'], 'input-1');
      expect(b.payloads.last['answers'], {
        'secret': {
          'answers': ['one private answer'],
        },
      });
      expect(tester.takeException(), isNull);
      await c.cancelAll();
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final style in DashboardThemeStyle.values) {
    testWidgets(
      'explicit prepare/start and retained draft in ${style.name} at 320px',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final b = TasksBackend();
        final c = TasksController(
          TaskService(b),
          pollInterval: const Duration(days: 1),
        );
        final language = ValueNotifier(AppLanguage.zh);
        addTearDown(c.dispose);
        addTearDown(language.dispose);
        await c.initialize();
        await tester.pumpWidget(
          host(
            IndependentTasksPanel(
              controller: c,
              chooseWorkspace: () async => 'synthetic-choice',
            ),
            language,
            style,
          ),
        );
        await tester.pumpAndSettle();
        expect(b.calls, ['task_catalog']);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('task-prompt')),
            matching: find.byType(EditableText),
          ),
          'retained private prompt',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('task-choose-workspace')),
        );
        await tester.tap(find.byKey(const ValueKey('task-choose-workspace')));
        await tester.pumpAndSettle();
        language.value = AppLanguage.en;
        await tester.pumpAndSettle();
        expect(c.prompt, 'retained private prompt');
        expect(c.workspace, 'synthetic-choice');
        await tester.ensureVisible(find.byKey(const ValueKey('task-prepare')));
        await tester.tap(find.byKey(const ValueKey('task-prepare')));
        await tester.pumpAndSettle();
        expect(b.calls.where((x) => x == 'task_start'), isEmpty);
        await tester.ensureVisible(
          find.byKey(ValueKey('task-start-${c.tasks.single.taskId}')),
        );
        await tester.tap(
          find.byKey(ValueKey('task-start-${c.tasks.single.taskId}')),
        );
        await tester.pumpAndSettle();
        expect(b.calls.where((x) => x == 'task_start'), hasLength(1));
        expect(tester.takeException(), isNull);
        await c.cancelAll();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
