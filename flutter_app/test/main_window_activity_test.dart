import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/account_usage.dart';
import 'package:codex_timezone/services/desktop_monitor.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'pet_animation_test.dart' show AnimationUsage;

void main() {
  testWidgets(
    'hidden monitor mutes progress tickers while the query continues',
    (tester) async {
      timezone.initializeTimeZones();
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopMonitor.channel, (_) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DesktopMonitor.channel, null),
      );
      final pending = Completer<AccountUsage>();
      final service = AnimationUsage()..pending = pending;
      await tester.pumpWidget(
        LauncherApplication(
          backend: const PreviewBackend(),
          monitorEnabled: true,
          usageService: service,
          networkFactory: () => NetworkController(preview: true),
        ),
      );
      await tester.pumpAndSettle();
      final usage = tester
          .widget<AccountUsagePanel>(
            find.byType(AccountUsagePanel, skipOffstage: false),
          )
          .controller;
      expect(service.calls, 0);
      final query = usage.query(r'C:\Codex.exe');
      usage.setMainWindowVisible(false);
      await tester.pumpAndSettle();
      expect(usage.busy, true);
      expect(service.calls, 1);
      expect(tester.binding.transientCallbackCount, 0);
      List<String> clockTexts() => tester
          .widgetList<Text>(find.byType(Text, skipOffstage: false))
          .map((w) => w.data ?? '')
          .where((v) => RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(v))
          .toList();
      final frozen = clockTexts();
      expect(frozen, isNotEmpty);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(clockTexts(), frozen);
      final pageStage = find.byWidgetPredicate(
        (w) => w is Offstage && w.child is WorkspaceShell,
        skipOffstage: false,
      );
      expect(tester.widget<Offstage>(pageStage).offstage, true);

      usage.setMainWindowVisible(true);
      await tester.pump();
      expect(tester.widget<Offstage>(pageStage).offstage, false);
      expect(clockTexts(), isNot(equals(frozen)));
      await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      usage.setMainWindowVisible(false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      expect(usage.busy, true);
      expect(service.calls, 1);
      pending.complete(
        AccountUsage(
          email: null,
          plan: null,
          buckets: [],
          fetchedAt: DateTime.now(),
        ),
      );
      await query;
      await tester.pump();
      expect(usage.busy, false);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
