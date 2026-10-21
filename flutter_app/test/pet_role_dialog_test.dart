import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

void main() {
  testWidgets('role entry and import validation work in a narrow window', (
    tester,
  ) async {
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
    await tester.ensureVisible(find.byKey(const ValueKey('pet-roles')));
    await tester.tap(find.byKey(const ValueKey('pet-roles')));
    await tester.pumpAndSettle();
    expect(find.text('角色与本地立绘'), findsWidgets);
    await tester.ensureVisible(find.byKey(const ValueKey('import-pet-role')));
    await tester.tap(find.byKey(const ValueKey('import-pet-role')));
    await tester.pumpAndSettle();
    expect(find.text('请先填写角色名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
