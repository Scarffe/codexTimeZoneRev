import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

void main() {
  testWidgets('monitor settings are usable in a narrow window', (tester) async {
    timezone.initializeTimeZones();
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const LauncherApplication(preview: true, offlineTrial: true),
    );
    await tester.pumpAndSettle();
    final usage = tester
        .widget<AccountUsagePanel>(
          find.byType(AccountUsagePanel, skipOffstage: false),
        )
        .controller;
    await tester.tap(find.byKey(const ValueKey('workspace-accounts')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('monitor-settings')));
    await tester.tap(find.byKey(const ValueKey('monitor-settings')));
    await tester.pumpAndSettle();
    expect(find.text('监控与提醒设置'), findsOneWidget);
    expect(find.textContaining('关注会话与未关注的所选会话共用开关和静音'), findsOneWidget);
    expect(find.textContaining('离线试用仅本次生效'), findsOneWidget);
    final reduced = find.byKey(const ValueKey('reduced-motion'));
    expect(reduced, findsOneWidget);
    await tester.ensureVisible(reduced);
    await tester.tap(reduced);
    await tester.pumpAndSettle();
    expect(find.text('减少动态效果：开启'), findsOneWidget);
    expect(usage.reducedMotion, isTrue);
    await tester.tap(find.byKey(const ValueKey('alerts-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('低额度提醒：关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
