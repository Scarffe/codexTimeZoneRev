import 'package:codex_timezone/app/application.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;

void main() {
  setUpAll(timezone.initializeTimeZones);
  testWidgets('independent tasks are an explicit inbox subview', (
    tester,
  ) async {
    await tester.pumpWidget(const LauncherApplication(preview: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-sessions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inbox-tasks-tab')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
