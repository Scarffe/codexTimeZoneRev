import 'dart:async';

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/session_rhythm_store.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';
import 'package:codex_timezone/state/session_rhythm_controller.dart';
import 'package:codex_timezone/state/session_metrics_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageUsage;
import 'support/session_rhythm_fixture.dart';

class RhythmAppBackend implements SyntheticSessionBackend {
  final calls = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add({'command': command, ...payload});
    if (command == 'session_metrics') {
      if (payload['action'] == 'history' && pending != null) {
        return pending!.future;
      }
      if (payload['action'] == 'list') {
        return {
          'sessions': [
            for (final s in rhythmFixtureSources)
              {'id': s.sessionId, 'path': s.path, 'title': s.title},
          ],
        };
      }
      if (payload['action'] == 'history') {
        return {
          'historyVersion': 1,
          'sourceInfo': {
            'id': rhythmFixtureSources
                .where((s) => s.path == payload['path'])
                .first
                .sessionId,
          },
          'logEpoch': 1,
          'revision': 1,
          'catchingUp': false,
          'changed': false,
          'records': [],
          'nextOrder': null,
        };
      }
      return {
        'sourceInfo': {'id': 'rhythm-0'},
        'last': {'turnId': 'latest'},
        'current': {},
        'history': [],
      };
    }
    return const PreviewBackend().call(command, payload);
  }
}

Future<void> rhythmNative(String method) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        DesktopMonitor.channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) => done.complete(),
      );
  await done.future;
}

class FlushFailureStore extends SessionRhythmStore {
  FlushFailureStore() : super.memory();
  bool fail = true;
  @override
  Future<void> flush() async {
    if (fail) throw StateError('synthetic flush failure');
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  testWidgets(
    'cache restore is offline; native session jump leaves rhythm and locates current',
    (tester) async {
      final backend = RhythmAppBackend(), store = SessionRhythmStore.memory();
      await store.write(rhythmFixtureCache());
      final rhythm = SessionRhythmController(
        backend: backend,
        store: store,
        now: () => rhythmFixtureNow,
      );
      final metrics = SessionMetricsController(backend), usage = PageUsage();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            DesktopMonitor.channel,
            (call) async => call.method == 'mainVisible' ? true : null,
          );
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          networkFactory: () => NetworkController(preview: true),
          backend: backend,
          usageService: usage,
          monitorEnabled: true,
          rhythmController: rhythm,
          sessionMetricsController: metrics,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话节奏'));
      await tester.pumpAndSettle();
      expect(find.textContaining('缓存待重读'), findsOneWidget);
      expect(
        backend.calls.where((v) => v['command'] == 'session_metrics'),
        isEmpty,
      );
      expect(usage.calls, 0);
      expect(metrics.selected, isNull);
      await rhythmNative('sessionDetails');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('analysis-quota-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('rhythm-heatmap')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopMonitor.channel, null);
    },
  );
  test('exit cancels owned read, waits backend tail then exits; busy alone keeps alive', () async {
    final backend = RhythmAppBackend()..pending = Completer(),
        store = SessionRhythmStore.memory();
    final rhythm = SessionRhythmController(
      backend: backend,
      store: store,
      now: () => rhythmFixtureNow,
    );
    final usage = AccountUsageController(PageUsage());
    final methods = <String>[], snapshots = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
          methods.add(call.method);
          if (call.method == 'publish') snapshots.add(call.arguments as Map);
          return call.method == 'mainVisible' ? true : null;
        });
    final monitor = DesktopMonitor(usage, () => '', rhythm: rhythm)..start();
    final adding = rhythm.addSource(rhythmFixtureSources.first);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last['keepAlive'], true);
    final exiting = rhythmNative('exit');
    await Future<void>.delayed(Duration.zero);
    expect(rhythm.busy, false);
    expect(methods, isNot(contains('exit')));
    backend.pending!.complete({
      'historyVersion': 1,
      'sourceInfo': {'id': 'rhythm-0'},
      'logEpoch': 1,
      'revision': 1,
      'catchingUp': false,
      'records': [],
      'nextOrder': null,
    });
    await adding;
    await exiting;
    expect(methods.where((m) => m == 'exit').length, 1);
    expect(rhythm.turns, isEmpty);
    monitor.dispose();
    rhythm.dispose();
    usage.dispose();
  });
  test('exit flush error reports local failure and permits retry', () async {
    final store = FlushFailureStore(), backend = RhythmAppBackend();
    final rhythm = SessionRhythmController(backend: backend, store: store);
    final usage = AccountUsageController(PageUsage()),
        notices = <String>[],
        methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopMonitor.channel, (call) async {
          methods.add(call.method);
          return call.method == 'mainVisible' ? true : null;
        });
    final monitor = DesktopMonitor(
      usage,
      () => '',
      rhythm: rhythm,
      onNotice: notices.add,
    )..start();
    await rhythmNative('exit');
    expect(methods, isNot(contains('exit')));
    expect(notices.single, contains('退出清理未完成'));
    store.fail = false;
    await rhythmNative('exit');
    expect(methods.where((m) => m == 'exit').length, 1);
    monitor.dispose();
    rhythm.dispose();
    usage.dispose();
  });
}
