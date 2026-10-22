import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/app/application.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

void main() {
  testWidgets(
    'paused pet controls cannot be opened from the monitoring workspace',
    (tester) async {
      timezone.initializeTimeZones();
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const LauncherApplication(preview: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pet-roles')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workspace-monitor')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('monitor-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('monitor-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pet-roles')), findsNothing);
      expect(find.byKey(const ValueKey('import-pet-role')), findsNothing);
      expect(find.text('角色与本地立绘'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
