import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:timezone/data/latest.dart' as timezone;
import 'package:codex_timezone/app/application.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = Platform.environment['CAPTURE_UI'] == '1';
  setUpAll(() async {
    timezone.initializeTimeZones();
    if (capture) {
      final fonts = FontLoader('packages/forui/Inter')
        ..addFont(
          rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
        );
      await fonts.load();
      final icons = FontLoader('packages/forui_lucide/ForuiLucideIcons')
        ..addFont(rootBundle.load('packages/forui_lucide/assets/lucide.ttf'));
      await icons.load();
      final cjk = File(r'C:\Windows\Fonts\msyh.ttc');
      if (cjk.existsSync()) {
        final chinese = FontLoader('Microsoft YaHei')
          ..addFont(
            cjk.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await chinese.load();
      }
    }
  });
  testWidgets('Forui menus change appearance and switch timezone mode', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LauncherApplication(preview: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(
      tester.element(find.text('Codex 时区启动器')).theme.colors.brightness,
      Brightness.dark,
    );
    await tester.tap(find.text('地区时区').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定 UTC 偏移').last);
    await tester.pumpAndSettle();
    expect(find.text('不随夏令时变化；半小时地区请使用地区时区。'), findsOneWidget);
    expect(find.text('未保存修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final appearance in ['light', 'dark']) {
    for (final size in [
      const Size(1280, 900),
      const Size(760, 900),
      const Size(600, 800),
    ]) {
      testWidgets('$appearance ${size.width}x${size.height} has no overflow', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: LauncherApplication(
              preview: true,
              initialAppearance: appearance,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Codex 时区启动器'), findsOneWidget);
        expect(find.text('保存并启动'), findsOneWidget);
        expect(find.text('演示模式'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            final boundary =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('build/ui-review')
              ..createSync(recursive: true);
            File(
              '${directory.path}/$appearance-${size.width.toInt()}x${size.height.toInt()}.png',
            ).writeAsBytesSync(png!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -1200),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
