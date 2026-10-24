import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_timezone/app/theme.dart';
import 'package:codex_timezone/app/dashboard_style.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void expectOpaquePanel(WidgetTester tester, Finder option, FThemeData theme) {
  expect(option, findsOneWidget);
  final panels = tester
      .widgetList<DecoratedBox>(
        find.ancestor(of: option, matching: find.byType(DecoratedBox)),
      )
      .where(
        (box) => box.decoration == theme.selectStyle.contentStyle.decoration,
      );
  expect(
    panels,
    isNotEmpty,
    reason: 'The option must be inside a painted popup.',
  );
  for (final panel in panels) {
    expect((panel.decoration as ShapeDecoration).color!.a, 1);
  }
}

void main() {
  final buttonContrastRows = <Map<String, Object>>[];
  tearDownAll(() {
    final path = Platform.environment['THEME_BUTTON_CONTRAST_FILE'];
    if (path != null) {
      File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(buttonContrastRows),
      );
    }
  });
  double contrast(Color a, Color b) {
    final values = [a.computeLuminance(), b.computeLuminance()]..sort();
    return (values.last + 0.05) / (values.first + 0.05);
  }

  for (final (style, dark) in [
    for (final style in DashboardThemeStyle.values)
      for (final dark in [false, true]) (style, dark),
  ]) {
    test(
      '${style.id} ${dark ? 'dark' : 'light'} reading surfaces and text stay calm and readable',
      () {
        final palette = DashboardPalette.forBrightness(
          dark ? Brightness.dark : Brightness.light,
          style: style,
        );
        final theme = launcherTheme(dark, style: style);
        expect(
          palette.background.computeLuminance(),
          dark ? lessThan(0.03) : lessThan(0.85),
        );
        expect(
          palette.panel.computeLuminance(),
          dark ? lessThan(0.04) : lessThan(0.92),
        );
        for (final surface in [
          palette.background,
          palette.panel,
          palette.rail,
          palette.soft,
          palette.selected,
        ]) {
          expect(
            contrast(palette.foreground, surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(contrast(palette.muted, surface), greaterThanOrEqualTo(4.5));
          expect(
            contrast(palette.controlAccent, surface),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(
          contrast(theme.colors.primary, theme.colors.primaryForeground),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(
            theme.colors.destructive,
            theme.colors.destructiveForeground,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          {
            palette.dataBlue,
            palette.reasoning,
            palette.tool,
            palette.muted,
          }.length,
          4,
        );
        expect(palette.accent, palette.dataBlue);
        if (style == DashboardThemeStyle.tech) {
          final color = palette.dataBlue.toARGB32();
          final red = (color >> 16) & 255,
              green = (color >> 8) & 255,
              blue = color & 255;
          expect(blue - red, greaterThan(80));
          expect(blue - green, greaterThan(50));
        }
        if (style == DashboardThemeStyle.graphite) {
          expect(palette.dataBlue, isNot(palette.chromeAccent));
          expect(
            contrast(palette.controlForeground, palette.controlFill),
            greaterThanOrEqualTo(4.5),
          );
        }
        // Resolve actual component states and composite translucent destructive
        // fills over both surfaces used by the application.
        final buttonProblems = <String>[];
        for (final (name, button) in [
          ('primary', theme.buttonStyles.primary.base),
          ('secondary', theme.buttonStyles.secondary.base),
          ('outline', theme.buttonStyles.outline.base),
          ('ghost', theme.buttonStyles.ghost.base),
          ('destructive', theme.buttonStyles.destructive.base),
        ]) {
          expect(
            button.decoration.resolve({FTappableVariant.hovered}).color,
            isNot(button.decoration.resolve({}).color),
            reason: '${style.id} $name retains visible hover feedback',
          );
          for (final (state, states) in [
            ('base', <FTappableVariant>{}),
            ('hovered', {FTappableVariant.hovered}),
            ('pressed', {FTappableVariant.pressed}),
            ('focused', {FTappableVariant.focused}),
          ]) {
            for (final (surfaceName, surface) in [
              ('panel', palette.panel),
              ('background', palette.background),
            ]) {
              final fill = Color.alphaBlend(
                button.decoration.resolve(states).color ??
                    const Color(0x00000000),
                surface,
              );
              final text = Color.alphaBlend(
                button.contentStyle.textStyle.resolve(states).color!,
                fill,
              );
              final ratio = contrast(text, fill);
              buttonContrastRows.add({
                'style': style.id,
                'dark': dark,
                'button': name,
                'state': state,
                'surface': surfaceName,
                'fillArgb': fill.toARGB32(),
                'textArgb': text.toARGB32(),
                'ratio': ratio,
              });
              if (ratio < 4.5) {
                buttonProblems.add('$name $state on $surfaceName: $ratio');
              }
            }
          }
        }
        expect(
          buttonProblems,
          isEmpty,
          reason: '${style.id} dark=$dark enabled button text',
        );
        final primaryButton = theme.buttonStyles.primary.base;
        expect(primaryButton.decoration.resolve({}).color, palette.controlFill);
        expect(
          primaryButton.contentStyle.textStyle.resolve({}).color,
          palette.controlForeground,
        );
        expect(
          contrast(
            primaryButton.decoration.resolve({}).color!,
            primaryButton.contentStyle.textStyle.resolve({}).color!,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.style.focusedOutlineStyle.color, palette.panel),
          greaterThanOrEqualTo(3),
        );
        expect(theme.typography.body.md.fontSize, 14);
        expect(theme.typography.body.sm.fontSize, 13);
        expect(theme.typography.body.md.height, 1.5);
        expect(theme.typography.body.md.fontWeight, FontWeight.w400);
        expect(theme.typography.body.md.fontFamily, 'Segoe UI Variable Text');
        expect(theme.typography.body.md.fontFamilyFallback!.take(2), [
          'Microsoft YaHei UI',
          'Microsoft YaHei',
        ]);
        expect(
          theme.typography.body.md.fontFeatures ?? [],
          isNot(contains(FontFeature.tabularFigures())),
        );
      },
    );
  }
  final captureDirectory = Platform.environment['CAPTURE_THEME_UI_DIR'];
  setUpAll(() async {
    if (captureDirectory == null) return;
    for (final (family, filename) in [
      ('Segoe UI Variable Text', 'SegUIVar.ttf'),
      ('Segoe UI', 'segoeui.ttf'),
    ]) {
      final font = File('C:/Windows/Fonts/$filename');
      await (FontLoader(family)..addFont(
            font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
    final fonts = FontLoader('packages/forui/Inter')
      ..addFont(rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'));
    await fonts.load();
    final icons = FontLoader('packages/forui_lucide/ForuiLucideIcons')
      ..addFont(rootBundle.load('packages/forui_lucide/assets/lucide.ttf'));
    await icons.load();
    final cjk = File(r'C:\Windows\Fonts\msyh.ttc');
    if (cjk.existsSync()) {
      for (final family in ['Microsoft YaHei UI', 'Microsoft YaHei']) {
        final chinese = FontLoader(family)
          ..addFont(
            cjk.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await chinese.load();
      }
    }
  });

  Future<void> capturePanel(
    WidgetTester tester,
    GlobalKey key,
    String filename,
  ) async {
    if (captureDirectory == null) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(captureDirectory)
          ..createSync(recursive: true);
        File('${directory.path}/$filename.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  for (final (style, dark) in [
    for (final style in DashboardThemeStyle.values)
      for (final dark in [false, true]) (style, dark),
  ]) {
    for (final acrylic in [false, true]) {
      final name =
          '${style.id} ${dark ? 'dark' : 'light'} ${acrylic ? 'acrylic' : 'solid'}';

      test('$name keeps shared and interactive surfaces opaque', () {
        final theme = launcherTheme(dark, acrylic: acrylic, style: style);
        final solid = launcherTheme(dark, style: style);
        expect(theme.colors.card.a, 1);
        expect(theme.colors.background.a, 1);
        expect(theme.colors.foreground.a, 1);
        expect(theme.scaffoldStyle.backgroundColor.a, acrylic ? 0 : 1);

        final card = theme.cardStyle.decoration as ShapeDecoration;
        expect(
          card.color!.a,
          closeTo(acrylic ? (dark ? 0.48 : 0.54) : 1, 0.001),
        );
        expect(
          card.shape,
          (solid.cardStyle.decoration as ShapeDecoration).shape,
        );
        expect(
          card.shadows,
          (solid.cardStyle.decoration as ShapeDecoration).shadows,
        );

        for (final decoration in [
          theme.selectStyle.contentStyle.decoration,
          theme.popoverStyle.decoration,
          theme.popoverMenuStyle.decoration,
          theme.dialogStyle.decoration,
        ]) {
          expect((decoration as ShapeDecoration).color!.a, 1);
        }
        expect(theme.selectStyle.fieldStyles.md.color.base!.a, 1);
        expect(theme.textFieldStyles.md.color.base!.a, 1);
        // Search fields and menu items can be transparent inside the opaque
        // popup. Disabled controls retain Forui's separate faded appearance.
        expect(theme.selectStyle.searchStyle.fieldStyles.md.color.base, isNull);
      });

      testWidgets('$name paints opaque ordinary and searchable dropdowns', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(900, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final theme = launcherTheme(dark, acrylic: acrylic, style: style);
        final captureKey = GlobalKey();
        String? basicChoice;
        String? searchChoice;
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: ColoredBox(
              color: theme.colors.background,
              child: WidgetsApp(
                color: const Color(0xff18181b),
                debugShowCheckedModeBanner: false,
                supportedLocales: FLocalizations.supportedLocales,
                localizationsDelegates: FLocalizations.localizationsDelegates,
                builder: (context, child) => FTheme(
                  data: theme,
                  child: DefaultTextStyle(
                    style: theme.typography.body.md.copyWith(
                      color: theme.colors.foreground,
                    ),
                    child: child!,
                  ),
                ),
                onGenerateRoute: (settings) => PageRouteBuilder<void>(
                  settings: settings,
                  pageBuilder: (context, _, _) => FScaffold(
                    child: Center(
                      child: SizedBox(
                        width: 420,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FSelect<String>(
                              items: const {
                                'Basic alpha': 'alpha',
                                'Basic beta': 'beta',
                              },
                              control: FSelectControl.lifted(
                                value: 'alpha',
                                onChange: (value) => basicChoice = value,
                              ),
                            ),
                            const SizedBox(height: 20),
                            FSelect<String>.search(
                              items: const {
                                'Search alpha': 'alpha',
                                'Search beta': 'beta',
                              },
                              control: FSelectControl.lifted(
                                value: 'alpha',
                                onChange: (value) => searchChoice = value,
                              ),
                            ),
                            const SizedBox(height: 20),
                            const Text('页面正文：下拉列表应完整遮挡此处文字。'),
                            const Text('页面正文：菜单背景不应与底层内容交叉。'),
                            const Text('Page content behind the dropdown'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Basic alpha'));
        await tester.pumpAndSettle();
        expectOpaquePanel(tester, find.text('Basic beta'), theme);
        if (acrylic) {
          await capturePanel(
            tester,
            captureKey,
            '${style.id}-${dark ? 'dark' : 'light'}-ordinary-dropdown',
          );
        }
        await tester.tap(find.text('Basic beta'));
        await tester.pumpAndSettle();
        expect(basicChoice, 'beta');
        expect(find.text('Basic beta'), findsNothing);

        await tester.tap(find.text('Search alpha'));
        await tester.pumpAndSettle();
        expectOpaquePanel(tester, find.text('Search beta'), theme);
        if (acrylic) {
          await capturePanel(
            tester,
            captureKey,
            '${style.id}-${dark ? 'dark' : 'light'}-search-dropdown',
          );
        }
        final searchInput = find.byWidgetPredicate(
          (widget) => widget is EditableText && !widget.readOnly,
        );
        expect(searchInput, findsOneWidget);
        await tester.enterText(searchInput, 'Search b');
        await tester.pumpAndSettle();
        expectOpaquePanel(tester, find.text('Search beta'), theme);
        await tester.tap(find.text('Search beta'));
        await tester.pumpAndSettle();
        expect(searchChoice, 'beta');
        expect(find.text('Search beta'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
