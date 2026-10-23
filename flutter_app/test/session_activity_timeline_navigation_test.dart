import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/session_metrics_panel.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageUsage;
import 'session_activity_fixture.dart';
import 'workspace_navigation_test.dart' show WorkspaceBackend;

class TimelineNavigationBackend extends WorkspaceBackend {
  int epoch = 1;
  String turn = 'completed-a';
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final result = await super.call(command, payload);
    if (command == 'session_metrics' && payload['action'] != 'list') {
      result['logEpoch'] = epoch;
      final last = result['last'] as Map<String, dynamic>;
      last['turnId'] = turn;
      last['analysis'] = {'timeline': timelineFixture(count: 200)};
    }
    return result;
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'ten main and API switches keep timeline owner expansion scroll selection and request counts; identity resets only list',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final backend = TimelineNavigationBackend();
      final usage = PageUsage();
      await tester.pumpWidget(
        LauncherApplication(
          backend: backend,
          usageService: usage,
          networkFactory: () => NetworkController(preview: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
          .controller;
      controller.select(WorkspaceBackend.longPath);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('session-timeline-toggle')),
      );
      await tester.tap(find.byKey(const ValueKey('session-timeline-toggle')));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('session-timeline-list'));
      await tester.ensureVisible(list);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      scroll.position.jumpTo(120);
      await tester.pump();
      final calls = backend.sessionCalls;
      for (var i = 0; i < 10; i++) {
        await tester.tap(
          find.byKey(const ValueKey('measurement-independent-api')),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('session-timeline-chart')),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const ValueKey('measurement-current-session')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('workspace-launcher')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
        await tester.pump();
        expect(
          tester
              .widget<SessionMetricsPanel>(find.byType(SessionMetricsPanel))
              .controller,
          same(controller),
        );
        expect(controller.selected, WorkspaceBackend.longPath);
        expect(
          find.byKey(const ValueKey('session-timeline-chart')),
          findsOneWidget,
        );
        expect(scroll.position.pixels, 120);
      }
      expect(backend.sessionCalls, calls);
      expect(usage.calls, 0);
      await controller.poll();
      await tester.pump();
      expect(
        scroll.position.pixels,
        120,
        reason: 'same epoch/turn refresh must preserve position',
      );
      backend.turn = 'completed-b';
      await controller.poll();
      await tester.pump();
      expect(scroll.position.pixels, 0);
      expect(
        find.byKey(const ValueKey('session-timeline-chart')),
        findsOneWidget,
      );
      scroll.position.jumpTo(80);
      backend.epoch++;
      await controller.poll();
      await tester.pump();
      expect(scroll.position.pixels, 0);
      expect(
        find.byKey(const ValueKey('session-timeline-chart')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
    },
  );
}
