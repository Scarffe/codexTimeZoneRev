import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/account_usage_panel.dart';
import 'package:codex_timezone/app/dashboard_motion.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/services/network_info.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

import 'account_usage_page_test.dart' show PageBackend, PageUsage;

void main() {
  Widget surface({
    bool reduced = false,
    bool osReduced = false,
    bool visible = true,
    bool enabled = true,
    VoidCallback? onPress,
    Key? capture,
    bool dark = false,
  }) => MediaQuery(
    data: MediaQueryData(disableAnimations: osReduced),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: FTheme(
        data: dark ? darkLauncherTheme : lightLauncherTheme,
        child: DashboardMotionScope(
          reducedMotion: reduced,
          child: TickerMode(
            enabled: visible,
            child: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: DashboardPalette.forBrightness(
                  dark ? Brightness.dark : Brightness.light,
                ).background,
                child: Center(
                  child: SizedBox(
                    width: 300,
                    height: 240,
                    child: DashboardMotionBackdrop(
                      child: Center(
                        child: DashboardMotionFeedback(
                          enabled: enabled,
                          child: GestureDetector(
                            onTap: enabled ? onPress : null,
                            child: const SizedBox(
                              key: ValueKey('target'),
                              width: 44,
                              height: 44,
                              child: ColoredBox(color: Color(0xff808080)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Finder paintFinder() => find.descendant(
    of: find.byType(DashboardMotionBackdrop),
    matching: find.byType(CustomPaint),
  );
  void paintRings(WidgetTester tester, Canvas canvas) => tester
      .widget<CustomPaint>(paintFinder())
      .foregroundPainter!
      .paint(canvas, const Size(300, 240));

  testWidgets('application preference and hidden window reach dialog routes', (
    tester,
  ) async {
    timezone.initializeTimeZones();
    SharedPreferences.setMockInitialValues({});
    final service = PageUsage();
    await tester.pumpWidget(
      LauncherApplication(
        backend: PageBackend(),
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
    await tester.tap(find.byKey(const ValueKey('monitor-settings')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('reduced-motion'));
    expect(toggle, findsOneWidget);
    expect(DashboardMotionScope.enabledOf(tester.element(toggle)), isTrue);
    usage.setReducedMotion(true);
    await tester.pump();
    expect(DashboardMotionScope.enabledOf(tester.element(toggle)), isFalse);
    usage.setReducedMotion(false);
    usage.setMainWindowVisible(false);
    await tester.pump();
    expect(DashboardMotionScope.enabledOf(tester.element(toggle)), isFalse);
    usage.setMainWindowVisible(true);
    await tester.pump();
    expect(DashboardMotionScope.enabledOf(tester.element(toggle)), isTrue);
    expect(service.calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('primary clicks pass through and one two-ring burst settles', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(surface(onPress: () => taps++));
    await tester.tap(find.byKey(const ValueKey('target')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(taps, 1);
    expect(
      (Canvas c) => paintRings(tester, c),
      paintsExactlyCountTimes(#drawCircle, 2),
    );
    await tester.tapAt(const Offset(410, 310));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      (Canvas c) => paintRings(tester, c),
      paintsExactlyCountTimes(#drawCircle, 2),
    );
    expect(
      (Canvas c) => paintRings(tester, c),
      paints..everything((method, args) {
        if (method != #drawCircle) return true;
        return (args[1] as double) <= 150 && (args[2] as Paint).color.a <= .08;
      }),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect((Canvas c) => paintRings(tester, c), paintsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final suppression in ['app', 'os', 'page']) {
    testWidgets(
      '$suppression suppression cancels without replaying old burst',
      (tester) async {
        await tester.pumpWidget(surface());
        await tester.tapAt(const Offset(400, 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          (Canvas c) => paintRings(tester, c),
          paintsExactlyCountTimes(#drawCircle, 2),
        );
        await tester.pumpWidget(
          surface(
            reduced: suppression == 'app',
            osReduced: suppression == 'os',
            visible: suppression != 'page',
          ),
        );
        expect((Canvas c) => paintRings(tester, c), paintsNothing);
        await tester.pumpWidget(surface());
        await tester.pump(const Duration(milliseconds: 80));
        expect((Canvas c) => paintRings(tester, c), paintsNothing);
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }

  testWidgets('secondary clicks and disabled controls stay inactive', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(surface(enabled: false, onPress: () => taps++));
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(find.byKey(const ValueKey('target'))));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect((Canvas c) => paintRings(tester, c), paintsNothing);
    expect(taps, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final os in [false, true]) {
    testWidgets('${os ? 'OS' : 'app'} reduced motion keeps hover static', (
      tester,
    ) async {
      await tester.pumpWidget(surface(reduced: !os, osReduced: os));
      final target = find.byKey(const ValueKey('target'));
      final resting = tester.getRect(target);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(target), resting);
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'hover transforms paint only, settles and resets on page hiding',
    (tester) async {
      await tester.pumpWidget(surface());
      final target = find.byKey(const ValueKey('target'));
      final original = tester.getRect(target);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final enlarged = tester.getRect(target);
      expect(enlarged.width, greaterThan(original.width));
      expect(enlarged.width, lessThanOrEqualTo(original.width * 1.04));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(surface(visible: false));
      expect(tester.getRect(target), original);
      await tester.pumpWidget(surface());
      expect(tester.getRect(target), original);
      await mouse.removePointer();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('press from a settled hover eases rather than jumping', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    final target = find.byKey(const ValueKey('target'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final hoveredWidth = tester.getRect(target).width;
    await mouse.down(tester.getCenter(target));
    await tester.pump();
    expect(tester.getRect(target).width, closeTo(hoveredWidth, .01));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(target).width, lessThan(hoveredWidth));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  final frameDirectory = Platform.environment['DASHBOARD_MOTION_RENDER_DIR'];
  if (frameDirectory != null) {
    for (final dark in [false, true]) {
      for (final width in [320.0, 1280.0]) {
        testWidgets(
          'capture actual Flutter ${dark ? 'dark' : 'light'} $width motion',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 600);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final capture = GlobalKey();
            await tester.pumpWidget(surface(dark: dark, capture: capture));
            await tester.tap(find.byKey(const ValueKey('target')));
            var previous = 0;
            for (final elapsed in [0, 80, 160, 280, 420, 600]) {
              await tester.pump(Duration(milliseconds: elapsed - previous));
              previous = elapsed;
              await tester.runAsync(() async {
                final image =
                    await (capture.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(frameDirectory).create(recursive: true);
                await File(
                  '$frameDirectory/synthetic-controls-${dark ? 'dark' : 'light'}-${width.toInt()}-$elapsed.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          },
        );
      }
    }
  }
}
