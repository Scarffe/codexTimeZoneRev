import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/l10n/app_language.dart';
import 'package:codex_timezone/services/benchmark.dart';
import 'package:codex_timezone/state/benchmark_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'benchmark_fixtures.dart';

void main() {
  setUpAll(timezone.initializeTimeZones);
  testWidgets('English replay stays offline and locale updates native chrome', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('codex_timezone/window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'status': 'applied',
            for (final part in ['dark', 'caption', 'text', 'border'])
              '${part}Hresult': 0,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final backend = BenchmarkBackend();
    final owner = BenchmarkController(
      BenchmarkService(backend),
      pollInterval: const Duration(days: 1),
    );
    await owner.initialize();
    await tester.pumpWidget(
      LauncherApplication(preview: true, benchmarkController: owner),
    );
    await tester.pumpAndSettle();
    tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).onLanguage!(
      AppLanguage.en,
    );
    await tester.pump();
    await tester.pump();
    expect(calls.last.arguments['uiLanguage'], 'en');
    await tester.tap(find.byKey(const ValueKey('workspace-benchmark')));
    await tester.pumpAndSettle();
    expect(find.text('Independent API benchmark'), findsOneWidget);
    expect(
      find.text('Offline replay · Synthetic data · Client observations'),
      findsOneWidget,
    );
    expect(find.text('Start replay'), findsOneWidget);
    expect(find.text('TTFT · First response content'), findsOneWidget);
    expect(backend.sequence, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('benchmark-inspect-ttftMs')),
    );
    await tester.tap(find.byKey(const ValueKey('benchmark-inspect-ttftMs')));
    await tester.pumpAndSettle();
    expect(find.text('First content time − Request start'), findsOneWidget);
    expect(backend.sequence, 0);
    tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).onLanguage!(
      AppLanguage.zh,
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('首段内容时间 − 请求开始'), findsOneWidget);
    expect(find.text('TTFT · 首段响应'), findsWidgets);
    expect(backend.sequence, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
