import 'dart:async';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/application.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:codex_timezone/app/monitor_presentation.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/window_chrome.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('codex_timezone/window');
  final calls = <MethodCall>[];
  late WindowChrome chrome;
  setUpAll(timezone.initializeTimeZones);
  const applied = <String, Object>{
    'status': 'applied',
    'darkHresult': 0,
    'captionHresult': 0,
    'textHresult': 0,
    'borderHresult': 0,
  };
  const offlineWarning = '离线试用 · 公网、账号查询与客户端启动已停用；主题仅本次生效。';
  Future<WindowChromeResult> light() => chrome.apply(
    dark: false,
    captionArgb: 0xfff5f6f8,
    textArgb: 0xff202833,
    borderArgb: 0xffdce1e7,
  );
  Future<WindowChromeResult> dark() => chrome.apply(
    dark: true,
    captionArgb: 0xff14171c,
    textArgb: 0xffe4e9f0,
    borderArgb: 0xff353c47,
  );
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    chrome = WindowChrome();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return applied;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'optional tray roles serialize and role-only changes are not deduplicated',
    () async {
      final firstReply = Completer<Map<String, Object>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return calls.length == 1 ? firstReply.future : applied;
          });
      Future<WindowChromeResult> themed(int accent) => chrome.apply(
        dark: false,
        captionArgb: 0xfff5f6f8,
        textArgb: 0xff202833,
        borderArgb: 0xffdce1e7,
        menuSurfaceArgb: 0xfff0f3f0,
        menuSelectedArgb: 0xffd6e3e5,
        menuAccentArgb: accent,
        menuDangerArgb: 0xffb32f3d,
      );
      final first = themed(0xff246978);
      final second = themed(0xff246979);
      final duplicate = themed(0xff246979);
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));
      firstReply.complete(applied);
      await Future.wait([first, second, duplicate]);
      expect(calls, hasLength(2));
      expect(calls.first.arguments, {
        'dark': false,
        'captionArgb': 0xfff5f6f8,
        'textArgb': 0xff202833,
        'borderArgb': 0xffdce1e7,
        'menuSurfaceArgb': 0xfff0f3f0,
        'menuSelectedArgb': 0xffd6e3e5,
        'menuAccentArgb': 0xff246978,
        'menuDangerArgb': 0xffb32f3d,
      });
      expect(calls.last.arguments['menuAccentArgb'], 0xff246979);
      await light();
      expect(calls.last.arguments, isNot(contains('menuSurfaceArgb')));
      expect(calls, hasLength(3));
    },
  );

  test(
    'initial resolved palette sends exact ARGB independently of material',
    () async {
      final result = await light();
      expect(result.status, WindowChromeStatus.applied);
      expect(calls.single.method, 'setAppearance');
      expect(calls.single.arguments, {
        'dark': false,
        'captionArgb': 0xfff5f6f8,
        'textArgb': 0xff202833,
        'borderArgb': 0xffdce1e7,
      });
      expect(result.hresults.values, everyElement(0));
    },
  );

  test(
    'identical palettes deduplicate but every changed field is applied',
    () async {
      await light();
      await light();
      expect(calls, hasLength(1));
      await dark();
      expect(calls, hasLength(2));
      expect(calls.last.arguments['dark'], true);
      await chrome.apply(
        dark: true,
        captionArgb: 0xff14171c,
        textArgb: 0xffe4e9f0,
        borderArgb: 0xff353c48,
      );
      expect(calls, hasLength(3));
    },
  );

  test('each optional tray role participates in deduplication', () async {
    final roles = <int>[0xfff0f3f0, 0xffd6e3e5, 0xff246978, 0xffb32f3d];
    Future<WindowChromeResult> applyRoles() => chrome.apply(
      dark: false,
      captionArgb: 0xfff5f6f8,
      textArgb: 0xff202833,
      borderArgb: 0xffdce1e7,
      menuSurfaceArgb: roles[0],
      menuSelectedArgb: roles[1],
      menuAccentArgb: roles[2],
      menuDangerArgb: roles[3],
    );
    await applyRoles();
    for (var index = 0; index < roles.length; index++) {
      roles[index] += 1;
      await applyRoles();
      await applyRoles();
      expect(calls, hasLength(index + 2));
    }
  });

  test(
    'in-flight palettes serialize so an old native reply cannot win',
    () async {
      final firstReply = Completer<Map<String, Object>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (calls.length == 1) return firstReply.future;
            return applied;
          });
      final initial = light();
      final next = dark();
      final repeated = dark();
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));
      firstReply.complete(applied);
      await Future.wait([initial, next, repeated]);
      expect(calls, hasLength(2));
      expect(calls.last.arguments['dark'], true);
      await dark();
      expect(calls, hasLength(2));
    },
  );

  test('native partial support retains checked HRESULT diagnostics', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            ...applied,
            'status': 'partial',
            'captionHresult': -2147024809,
          },
        );
    final result = await dark();
    expect(result.status, WindowChromeStatus.partial);
    expect(result.hresults['caption'], -2147024809);
    expect(result.hresults['text'], 0);
  });

  test(
    'missing plugin and platform failure are safe typed results and retryable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw MissingPluginException(),
          );
      expect((await light()).status, WindowChromeStatus.unsupported);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'unavailable'),
          );
      expect((await light()).status, WindowChromeStatus.failed);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return applied;
          });
      expect((await light()).status, WindowChromeStatus.applied);
      expect(calls, hasLength(1));
    },
  );

  test(
    'unsupported and malformed replies do not masquerade as full support',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {'status': 'unsupported'},
          );
      expect((await light()).status, WindowChromeStatus.unsupported);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => {'unexpected': true});
      expect((await dark()).status, WindowChromeStatus.failed);
    },
  );

  for (final acrylic in [false, true]) {
    testWidgets(
      'resolved initial and explicit palettes sync with acrylic=$acrylic',
      (tester) async {
        const material = MethodChannel('com.alexmercerind/flutter_acrylic');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(material, (_) async => null);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(material, null),
        );
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          LauncherApplication(
            preview: true,
            initialAppearance: 'light',
            acrylicEnabled: acrylic,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(offlineWarning), findsNothing);
        final palette = DashboardPalette.forBrightness(Brightness.light);
        expect(calls, hasLength(1));
        expect(calls.single.arguments, {
          'dark': false,
          'captionArgb': palette.background.toARGB32(),
          'textArgb': palette.foreground.toARGB32(),
          'borderArgb': palette.border.toARGB32(),
          'menuSurfaceArgb': palette.panel.toARGB32(),
          'menuSelectedArgb': palette.selected.toARGB32(),
          'menuAccentArgb': palette.accent.toARGB32(),
          'menuDangerArgb': palette.danger.toARGB32(),
        });
        await tester.pump();
        expect(calls, hasLength(1));
        final brand = find.byKey(const ValueKey('workspace-brand-mark'));
        expect(brand, findsOneWidget);
        expect(
          tester.widget<Image>(brand).image,
          isA<AssetImage>().having(
            (image) => image.assetName,
            'asset',
            'assets/app_icon.png',
          ),
        );
        final about = find.byKey(const ValueKey('workspace-about'));
        expect(tester.getSize(about), const Size(44, 44));
        await tester.tap(about);
        await tester.pumpAndSettle();
        expect(find.text('Codex 时区启动器'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace-theme')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('深色').last);
        await tester.pumpAndSettle();
        expect(calls, hasLength(2));
        expect(calls.last.arguments['dark'], true);
        expect(
          calls.last.arguments['captionArgb'],
          DashboardPalette.forBrightness(Brightness.dark).background.toARGB32(),
        );
        // Existing shared icon controls still take the public icon-only path.
        final themeAction = tester.widget<MonitorIconAction>(
          find.byKey(const ValueKey('workspace-theme')),
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('workspace-theme')),
            matching: find.byIcon(themeAction.icon),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'system changes update native colors while explicit choice wins',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(const LauncherApplication(preview: true));
      await tester.pumpAndSettle();
      expect(calls.single.arguments['dark'], true);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls.last.arguments['dark'], false);
      await tester.tap(find.byKey(const ValueKey('workspace-theme')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      expect(calls, hasLength(3));
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(calls, hasLength(3));
      expect(calls.last.arguments['dark'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unsupported native frame retains usable themed application', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {'status': 'unsupported'};
        });
    await tester.pumpWidget(
      const LauncherApplication(preview: true, initialAppearance: 'light'),
    );
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(find.byKey(const ValueKey('workspace-theme')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-brand-mark')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-theme')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(calls.last.arguments['dark'], true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final initial in [Brightness.dark, Brightness.light]) {
    testWidgets(
      'offline warning paints readable surface from $initial through theme switch',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: LauncherApplication(
              preview: true,
              backend: const PreviewBackend(),
              offlineTrial: true,
              initialAppearance: initial == Brightness.dark ? 'dark' : 'light',
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final brightness in [
          initial,
          initial == Brightness.dark ? Brightness.light : Brightness.dark,
        ]) {
          if (brightness != initial) {
            await tester.tap(find.byKey(const ValueKey('workspace-theme')));
            await tester.pumpAndSettle();
            await tester.tap(
              find.text(brightness == Brightness.dark ? '深色' : '浅色').last,
            );
            await tester.pumpAndSettle();
          }
          final warning = find.text(offlineWarning);
          expect(warning, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(warning);
          final foreground = paragraph.text.style!.color!;
          final y = tester.getRect(warning).center.dy.round();
          final background = (await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final frame = await boundary.toImage(pixelRatio: 1);
            final pixels = (await frame.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            // Sample clear left padding on the actual painted banner row.
            final offset = (y * frame.width + 2) * 4;
            final color = Color.fromARGB(
              pixels.getUint8(offset + 3),
              pixels.getUint8(offset),
              pixels.getUint8(offset + 1),
              pixels.getUint8(offset + 2),
            );
            frame.dispose();
            return color;
          }))!;
          expect(
            background.a,
            1,
            reason: 'banner must paint its own opaque surface, including outside the text width',
          );
          final palette = DashboardPalette.forBrightness(brightness);
          expect(background, palette.soft);
          expect(foreground, palette.foreground);
          final a = background.computeLuminance(),
              b = foreground.computeLuminance();
          final contrast = a > b
              ? (a + .05) / (b + .05)
              : (b + .05) / (a + .05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: 'offline warning must remain readable after theme changes',
          );
          await tester.pump(const Duration(seconds: 1));
          expect(
            tester.renderObject<RenderParagraph>(warning).text.style!.color,
            foreground,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
