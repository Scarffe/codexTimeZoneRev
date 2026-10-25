import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/services/account_sources.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'support/multi_account_fixture.dart';
import 'support/quota_history_fixture.dart';

import 'package:codex_timezone/app/account_sources_panel.dart';

import 'chart_overview_test.dart' show overviewGraphKeys;

class _DeniedBackend implements LauncherBackend {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add(command);
    throw StateError('Native source operation must not be reached');
  }
}

void main() {
  setUpAll(timezone.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'offline app accepts pure synthetic owner and retains five real charts',
    (tester) async {
      final f = await syntheticMultiFixture();
      final history = await HistoryFixture.create(records: []);
      addTearDown(history.owner.dispose);
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: f.backend,
          sourceController: f.owner,
          historyController: history.controller,
          sessionMetricsController: f.metrics,
          desktop: SyntheticMultiDesktop(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-source-selector')),
        findsOneWidget,
      );
      final manager = tester.state(find.byType(AccountSourcesPanel));
      final queries = f.service.queries.length;
      await tester.tap(find.byKey(const ValueKey('accounts-history')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(AccountSourcesPanel)), same(manager));
      expect(f.service.queries.length, queries);
      await tester.tap(find.byKey(const ValueKey('workspace-analysis')));
      await tester.pumpAndSettle();
      for (final key in overviewGraphKeys) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(f.metrics.selected, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline app rejects non synthetic injected owner before all source operations',
    (tester) async {
      final backend = _DeniedBackend();
      final owner = AccountSourcesController(
        NativeAccountSourcesService(backend),
        AccountSourceStore.memory(),
      );
      await tester.pumpWidget(
        LauncherApplication(
          offlineTrial: true,
          backend: backend,
          sourceController: owner,
          desktop: SyntheticMultiDesktop(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-source-selector')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('query-account-usage')));
      await tester.pumpAndSettle();
      expect(
        backend.calls.where((command) => command.startsWith('account_source_')),
        isEmpty,
      );
      expect(owner.states, isEmpty);
      expect(owner.selected, isNull);
      expect(owner.pinned, isNull);
      await tester.pumpWidget(const SizedBox());
      owner.dispose();
    },
  );
}
