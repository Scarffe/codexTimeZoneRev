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
    bool fullClient = false,
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
                    width: fullClient ? null : 300,
                    height: fullClient ? null : 240,
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

  Finder paintFinder() => find
      .descendant(
        of: find.byType(DashboardMotionBackdrop),
        matching: find.byType(CustomPaint),
      )
      .first;
  void paintRings(WidgetTester tester, Canvas canvas) => tester
      .widget<CustomPaint>(paintFinder())
      .foregroundPainter!
      .paint(canvas, const Size(300, 240));

  List<({Offset center, double radius, double alpha})> rings(
    WidgetTester tester, {
    Size size = const Size(300, 240),
  }) {
    final canvas = TestRecordingCanvas();
    tester
        .widget<CustomPaint>(paintFinder())
        .foregroundPainter!
        .paint(canvas, size);
    return [
      for (final call in canvas.invocations)
        if (call.invocation.memberName == #drawCircle)
          (
            center: call.invocation.positionalArguments[0] as Offset,
            radius: call.invocation.positionalArguments[1] as double,
            alpha: (call.invocation.positionalArguments[2] as Paint).color.a,
          ),
    ];
  }

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
    expect(
      find.ancestor(of: toggle, matching: find.byType(DashboardMotionBackdrop)),
      findsOneWidget,
      reason: 'the single client decoration must include Navigator dialogs',
    );
    expect(find.byType(DashboardMotionBackdrop), findsOneWidget);
    final contact = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await contact.down(tester.getCenter(toggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(rings(tester, size: tester.view.physicalSize), isNotEmpty);
    await contact.up();
    await tester.pumpAndSettle();
    expect(service.calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('control and blank primary contacts remain visible past 480ms', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(surface(onPress: () => taps++));
    await tester.tap(find.byKey(const ValueKey('target')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(taps, 1);
    expect(rings(tester).any((r) => r.alpha >= .18), isTrue);
    final bounds = tester.getRect(find.byType(DashboardMotionBackdrop));
    await tester.tapAt(bounds.topLeft + const Offset(35, 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      rings(tester).map((r) => r.center).toSet(),
      containsAll([const Offset(150, 120), const Offset(35, 40)]),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(rings(tester), isNotEmpty);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(const Duration(seconds: 4));
    expect((Canvas c) => paintRings(tester, c), paintsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'popover and toast primary contacts paint above overlays without consuming actions',
    (tester) async {
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
      final theme = find.byKey(const ValueKey('workspace-theme'));
      await tester.tap(theme);
      await tester.pumpAndSettle();
      final choice = find.text('深色');
      final menuPoint = tester.getCenter(choice);
      await tester.tap(choice);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final client = tester.getTopLeft(find.byType(DashboardMotionBackdrop));
      expect(
        rings(tester, size: tester.view.physicalSize).map((r) => r.center),
        contains(menuPoint - client),
      );
      await tester.pumpAndSettle();
      expect(tester.element(theme).theme.colors.brightness, Brightness.dark);
      var toastTaps = 0;
      final toast = showRawFToast(
        context: tester.element(theme),
        duration: null,
        swipeToDismiss: const [],
        builder: (_, _) => GestureDetector(
          onTap: () => toastTaps++,
          child: const SizedBox(
            key: ValueKey('neutral-toast-contact'),
            width: 120,
            height: 60,
            child: ColoredBox(color: Color(0xff808080)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toastPoint = tester.getCenter(
        find.byKey(const ValueKey('neutral-toast-contact')),
      );
      await tester.tapAt(toastPoint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(toastTaps, 1);
      expect(
        rings(tester, size: tester.view.physicalSize).map((r) => r.center),
        contains(toastPoint - client),
      );
      expect(service.calls, 0);
      toast.dismiss();
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'all four walls reflect at travel time with weaker mirrored crests',
    (tester) async {
      await tester.pumpWidget(surface());
      final bounds = tester.getRect(find.byType(DashboardMotionBackdrop));
      await tester.tapAt(bounds.topLeft + const Offset(30, 50));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      final early = rings(tester);
      expect(
        early.map((r) => r.center),
        containsAll([
          const Offset(30, 50),
          const Offset(-30, 50),
          const Offset(30, -50),
        ]),
      );
      final direct = early.firstWhere((r) => r.center == const Offset(30, 50));
      final left = early.firstWhere((r) => r.center == const Offset(-30, 50));
      final top = early.firstWhere((r) => r.center == const Offset(30, -50));
      expect(direct.radius, closeTo(60, .01));
      expect(left.radius, direct.radius);
      expect(top.radius, direct.radius);
      expect(left.alpha / direct.alpha, closeTo(.58, .025));
      expect(top.alpha / direct.alpha, closeTo(.58, .025));
      expect(early.any((r) => r.center == const Offset(570, 50)), isFalse);
      await tester.pump(const Duration(milliseconds: 475));
      final later = rings(tester);
      expect(later.any((r) => r.center == const Offset(570, 50)), isTrue);
      expect(later.any((r) => r.center == const Offset(30, 430)), isTrue);
      final faded = later.firstWhere((r) => r.center == const Offset(-30, 50));
      expect(faded.alpha, lessThan(left.alpha));
      expect(faded.radius, closeTo(288, .01));
      final canvas = TestRecordingCanvas();
      paintRings(tester, canvas);
      expect(
        canvas.invocations.any((c) => c.invocation.memberName == #saveLayer),
        isFalse,
      );
      expect(later.length, lessThanOrEqualTo(82));
      await tester.pump(const Duration(seconds: 4));
      expect(rings(tester), isEmpty);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('rapid primary contacts keep only four recent event origins', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    final bounds = tester.getRect(find.byType(DashboardMotionBackdrop));
    const points = [
      Offset(20, 35),
      Offset(60, 70),
      Offset(110, 95),
      Offset(160, 130),
      Offset(220, 180),
    ];
    for (final point in points) {
      await tester.tapAt(bounds.topLeft + point);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final marks = rings(tester);
    final directCenters = marks
        .where((r) => bounds.size.contains(r.center))
        .map((r) => r.center)
        .toSet();
    expect(directCenters, points.skip(1).toSet());
    expect(marks.length, lessThanOrEqualTo(328));
    await tester.pump(const Duration(seconds: 4));
    expect(rings(tester), isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'disabled primary target still shows neutral contact without activation',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(surface(enabled: false, onPress: () => taps++));
      await tester.tap(find.byKey(const ValueKey('target')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(taps, 0);
      expect(rings(tester).any((r) => r.alpha >= .18), isTrue);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  for (final suppression in ['app', 'os', 'page']) {
    testWidgets(
      '$suppression suppression cancels without replaying old burst',
      (tester) async {
        await tester.pumpWidget(surface());
        await tester.tapAt(const Offset(400, 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(rings(tester), isNotEmpty);
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
            await tester.pumpWidget(
              surface(dark: dark, capture: capture, fullClient: true),
            );
            await tester.tapAt(const Offset(24, 90));
            await tester.pump();
            var previous = 0;
            for (final elapsed in [
              0,
              80,
              125,
              280,
              600,
              1400,
              2400,
              3900,
              4100,
            ]) {
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
            expect(tester.binding.transientCallbackCount, 0);
          },
        );
      }
    }
  }
}
