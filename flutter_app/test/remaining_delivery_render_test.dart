import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/tasks.dart';
import 'package:codex_timezone/state/tasks_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
import 'support/workspace_attention_fixture.dart';
import 'tasks_fixture.dart';

// Six representative cases: every theme in light/dark, both languages,
// 760px light and 1280px dark at 125% text. Synthetic backend only.
const _cases = [
  (DashboardThemeStyle.soft, 'light', AppLanguage.zh, 760.0),
  (DashboardThemeStyle.soft, 'dark', AppLanguage.en, 1280.0),
  (DashboardThemeStyle.tech, 'light', AppLanguage.en, 760.0),
  (DashboardThemeStyle.tech, 'dark', AppLanguage.zh, 1280.0),
  (DashboardThemeStyle.graphite, 'light', AppLanguage.zh, 760.0),
  (DashboardThemeStyle.graphite, 'dark', AppLanguage.en, 1280.0),
];

void main() {
  final output =
      Platform.environment['REMAINING_RENDER_DIR'] ??
      Platform.environment['LOCALE_RENDER_DIR'];
  setUpAll(() async {
    timezone.initializeTimeZones();
    for (final (family, asset) in [
      ('packages/forui/Inter', 'packages/forui/assets/fonts/inter/Inter.ttf'),
      (
        'packages/forui_lucide/ForuiLucideIcons',
        'packages/forui_lucide/assets/lucide.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    for (final (family, file) in [
      ('Segoe UI', 'segoeui.ttf'),
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
      ('Microsoft YaHei UI', 'msyh.ttc'),
      ('Microsoft YaHei', 'msyh.ttc'),
    ]) {
      final font = File('C:/Windows/Fonts/$file');
      if (font.existsSync()) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final (style, appearance, language, width) in _cases) {
    final name = '${style.id}-$appearance-${language.name}-${width.toInt()}';
    testWidgets('$name independent task form/card/approval actual fonts', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1100);
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final f = await WorkspaceAttentionFixture.create();
      final selectedSource = f.sources.selectedId,
          selectedSession = f.metrics.selected;
      final backend = TasksBackend();
      final tasks = TasksController(
        TaskService(backend),
        pollInterval: const Duration(days: 1),
      );
      await tasks.initialize();
      tasks.updateDraft(
        prompt: '检查合成工作区的只读流程，并列出待确认事项。 Review the synthetic workspace without changing files.',
        workspace: r'C:\synthetic-only\coursework\remaining-delivery',
        model: 'synthetic-model-v1',
      );
      final task = (await tasks.prepare())!;
      await tasks.start(task);
      backend.tasks[task.taskId]!.addAll({
        'state': 'awaiting_approval',
        'output': '合成任务已准备好，只读工作区保持独立。\nSynthetic task output: review this pending operation before continuing.',
        'usage': {
          'scope': 'thread_total',
          'inputTokens': 128,
          'outputTokens': 64,
          'reasoningTokens': 16,
        },
        'approvals': [
          {
            'approvalId': 'render-approval',
            'kind': 'command',
            'summary': '合成命令审批 / Synthetic command review',
            'command': 'Get-ChildItem -LiteralPath synthetic-only',
            'cwd': r'C:\synthetic-only\coursework\remaining-delivery',
            'files': <String>[],
          },
        ],
      });
      await tasks.poll();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: LauncherApplication(
            offlineTrial: true,
            initialThemeStyle: style,
            initialAppearance: appearance,
            backend: f.backend,
            desktop: SyntheticMultiDesktop(),
            sourceController: f.sources,
            sessionMetricsController: f.metrics,
            attentionController: f.attention,
            benchmarkController: f.benchmark,
            tasksController: tasks,
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).onLanguage!(
        language,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inbox-tasks-tab')));
      await tester.pumpAndSettle();
      Future<void> capture(String suffix) async {
        expect(tester.takeException(), isNull, reason: '$name $suffix');
        expect(f.sources.selectedId, selectedSource);
        expect(f.metrics.selected, selectedSession);
        expect(
          backend.calls.where((call) => call == 'task_start'),
          hasLength(1),
        );
        if (output == null) return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = Directory('$output/tasks');
            await directory.create(recursive: true);
            final file = File('${directory.path}/$name-$suffix.png');
            if (await file.exists()) {
              throw StateError(
                'Do not overwrite render evidence: ${file.path}',
              );
            }
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await capture('form');
      await Scrollable.ensureVisible(
        tester.element(find.byKey(ValueKey('task-card-${task.taskId}'))),
        alignment: .05,
      );
      await tester.pumpAndSettle();
      await capture('task');
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-approval-render-approval')),
      );
      await tester.tap(
        find.byKey(const ValueKey('task-approval-render-approval')),
      );
      await tester.pumpAndSettle();
      await capture('approval');
      await tester.tap(find.byKey(const ValueKey('monitor-information-close')));
      await tester.pumpAndSettle();
      await tasks.cancelAll();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
