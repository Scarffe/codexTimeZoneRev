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
    await tester.pumpWidget(const LauncherApplication(preview: true));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('monitor-settings')));
    await tester.tap(find.byKey(const ValueKey('monitor-settings')));
    await tester.pumpAndSettle();
    expect(find.text('监控与提醒设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('alerts-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('低额度提醒：关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
