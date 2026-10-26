import 'dart:async';

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/tasks.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/tasks_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'benchmark_offline_policy_test.dart' show DeniedUsage;
import 'monitor_lifecycle_test.dart' show nativeAction;
import 'support/multi_account_fixture.dart';
import 'support/workspace_attention_fixture.dart';
import 'tasks_fixture.dart';

class _OrderedTasks extends TasksBackend {
  _OrderedTasks(this.events);
  final List<String> events;
  Completer<Map<String, dynamic>>? shutdownGate;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) {
    events.add(command);
    if (command == 'task_shutdown' && shutdownGate != null) {
      return shutdownGate!.future;
    }
    return super.call(command, payload);
  }
}

class _OrderedSources extends SyntheticMultiSources {
  _OrderedSources(this.events);
  final List<String> events;
  @override
  Future<void> shutdown() async {
    events.add('source_shutdown');
    await super.shutdown();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <String>[];
  final published = <Map>[];
  setUp(() {
    nativeCalls.clear();
    published.clear();
    messenger.setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'mainVisible') return true;
      if (call.method == 'publish') published.add(call.arguments as Map);
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(DesktopMonitor.channel, null),
  );
  testWidgets(
    'injected offline owner rejects official execution and navigation preserves independent selections',
    (tester) async {
      final f = await WorkspaceAttentionFixture.create();
      final raw = TasksBackend();
      final tasks = TasksController(
        TaskService(raw),
        pollInterval: const Duration(days: 1),
      );
      await tasks.initialize();
      tasks.updateDraft(
        mode: 'official',
        sourceId: 'profile-primary',
        workspace: 'synthetic-only',
        model: 'synthetic-model',
        prompt: 'synthetic task',
      );
      final official = (await tasks.prepare())!;
      raw.calls.clear();
      raw.payloads.clear();
      f.sources.select('profile-unknown');
      final source = f.sources.selectedId, session = f.metrics.selected;
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: f.backend,
          sourceController: f.sources,
          sessionMetricsController: f.metrics,
          attentionController: f.attention,
          benchmarkController: f.benchmark,
          tasksController: tasks,
        ),
      );
      await tester.pumpAndSettle();
      expect(tasks.officialEnabled, false);
      await expectLater(
        tasks.service.prepare(
          mode: 'official',
          sourceId: 'profile-primary',
          workspace: 'synthetic-only',
          model: 'synthetic-model',
          prompt: 'synthetic task',
        ),
        throwsA(isA<TaskFailure>()),
      );
      await tasks.start(official);
      for (final workspace in [
        'sessions',
        'accounts',
        'analysis',
        'benchmark',
        'overview',
        'sessions',
      ]) {
        await tester.tap(find.byKey(ValueKey('workspace-$workspace')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('inbox-tasks-tab')));
      await tester.pumpAndSettle();
      expect(
        raw.calls.where(
          (call) => call == 'task_prepare' || call == 'task_start',
        ),
        isEmpty,
      );
      expect(f.sources.selectedId, source);
      expect(f.metrics.selected, session);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'active tasks hide on close; suspend cancels and resume never restarts',
    (tester) async {
      final backend = TasksBackend();
      final tasks = TasksController(
        TaskService(backend),
        pollInterval: const Duration(days: 1),
      );
      final usage = AccountUsageController(DeniedUsage(), offlineTrial: true);
      final bridge = DesktopMonitor(usage, () => '', tasks: tasks);
      addTearDown(tasks.dispose);
      addTearDown(usage.dispose);
      await tasks.initialize();
      tasks.updateDraft(prompt: 'synthetic');
      final task = (await tasks.prepare())!;
      await tasks.start(task);
      bridge.start();
      await tester.pump();
      expect(published.last['keepAlive'], true);
      await nativeAction('closeRequested');
      expect(nativeCalls, contains('hide'));
      expect(nativeCalls, isNot(contains('exit')));
      await nativeAction('systemSuspend');
      expect(tasks.tasks.single.state, 'cancelled');
      await nativeAction('systemResume');
      await tester.pump();
      expect(backend.calls.where((call) => call == 'task_start'), hasLength(1));
      expect(
        backend.calls.where((call) => call == 'task_prepare'),
        hasLength(1),
      );
      bridge.dispose();
    },
  );
  testWidgets(
    'exit waits task cleanup before source shutdown and native exit',
    (tester) async {
      final order = <String>[];
      final backend = _OrderedTasks(order)
        ..shutdownGate = Completer<Map<String, dynamic>>();
      final tasks = TasksController(
        TaskService(backend),
        pollInterval: const Duration(days: 1),
      );
      final sourceService = _OrderedSources(order);
      final sources = AccountSourcesController(
        sourceService,
        AccountSourceStore.memory(),
        offlineTrial: true,
      );
      await sources.initialize(() => '');
      final usage = AccountUsageController(
        DeniedUsage(),
        sources: sources,
        offlineTrial: true,
      );
      final bridge = DesktopMonitor(usage, () => '', tasks: tasks);
      addTearDown(tasks.dispose);
      addTearDown(usage.dispose);
      addTearDown(sources.dispose);
      await tasks.initialize();
      tasks.updateDraft(prompt: 'synthetic');
      final task = (await tasks.prepare())!;
      await tasks.start(task);
      bridge.start();
      await tester.pump();
      final exit = nativeAction('exit');
      await tester.pump();
      expect(order, contains('task_shutdown'));
      expect(order, isNot(contains('source_shutdown')));
      expect(nativeCalls, isNot(contains('exit')));
      backend.shutdownGate!.complete({
        'accepting': false,
        'cleanupComplete': true,
      });
      await exit;
      expect(
        order.indexOf('task_shutdown'),
        lessThan(order.indexOf('source_shutdown')),
      );
      expect(nativeCalls.where((call) => call == 'exit'), hasLength(1));
      bridge.dispose();
    },
  );
}
