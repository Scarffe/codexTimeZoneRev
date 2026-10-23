import 'dart:ui' show Tristate;

import 'package:codex_timezone/app/session_measurement_workspace.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/app/workspace_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

Widget host(Widget child) => WidgetsApp(
  color: const Color(0xfff5f6f8),
  localizationsDelegates: FLocalizations.localizationsDelegates,
  supportedLocales: FLocalizations.supportedLocales,
  pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (context, _, _) => builder(context),
  ),
  builder: (context, child) => FTheme(
    data: launcherTheme(false),
    child: FTooltipGroup(child: child!),
  ),
  home: child,
);

void main() {
  testWidgets('rail navigation announces the visible monitor overview', (
    tester,
  ) async {
    var monitor = false;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, update) => WorkspaceShell(
            monitorSelected: monitor,
            onSelect: (value) => update(() => monitor = value),
            appearance: 'light',
            onAppearance: (_) {},
            launcher: const Text('launcher content'),
            monitor: const Text('monitor content'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();
    final monitorAction = find.byKey(const ValueKey('workspace-monitor'));
    final launcherNode = tester.getSemantics(
      find.byKey(const ValueKey('workspace-launcher')),
    );
    expect(launcherNode.getSemanticsData().label, contains('时区启动器'));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('workspace-launcher')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    var monitorFocused = false;
    for (var step = 0; step < 8; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final button = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<FButton>();
      if (button?.semanticsLabel == '监控与工具') {
        monitorFocused = true;
        break;
      }
    }
    expect(
      monitorFocused,
      isTrue,
      reason: 'Icon navigation remains keyboard reachable',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('监控总览'), findsOneWidget);
    expect(
      tester.getSemantics(monitorAction).getSemanticsData().label,
      contains('监控与工具'),
    );
    expect(
      tester.getSemantics(monitorAction).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(find.text('monitor content'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Let focus/tooltip UI timers finish without hiding framework exceptions.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 600));
    semantics.dispose();
  });

  testWidgets('source segments expose selection and preserve mounted content', (
    tester,
  ) async {
    final source = ValueNotifier(false);
    addTearDown(source.dispose);
    final field = TextEditingController(text: 'retained draft');
    addTearDown(field.dispose);
    final focus = FocusNode()..skipTraversal = true;
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      host(
        SessionMeasurementWorkspace(
          independentApiSelected: source,
          currentSession: EditableText(
            controller: field,
            focusNode: focus,
            style: const TextStyle(),
            cursorColor: const Color(0xff345eaf),
            backgroundCursorColor: const Color(0xff345eaf),
          ),
          independentApi: const Text('offline independent content'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();
    final current = find.byKey(const ValueKey('measurement-current-session'));
    expect(
      tester.getSemantics(current).getSemanticsData().label,
      contains('当前会话'),
    );
    final independent = find.byKey(
      const ValueKey('measurement-independent-api'),
    );
    expect(
      tester.getSemantics(current).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    await tester.tap(independent);
    await tester.pumpAndSettle();
    expect(source.value, isTrue);
    expect(
      tester.getSemantics(independent).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(find.text('offline independent content'), findsOneWidget);
    expect(find.byType(EditableText, skipOffstage: false), findsOneWidget);
    await tester.tap(current);
    await tester.pumpAndSettle();
    expect(field.text, 'retained draft');
    expect(
      tester.getSemantics(current).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });
}
