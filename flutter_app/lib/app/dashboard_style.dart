import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

enum DashboardThemeStyle {
  soft('柔和·雾杉'),
  tech('科技·极昼'),
  graphite('石墨·香槟');

  const DashboardThemeStyle(this.label);
  final String label;
  String get id => name;
  static DashboardThemeStyle parse(Object? value) =>
      values.where((style) => style.id == value).firstOrNull ?? soft;
}

/// Palette family policy for pages and Navigator overlays; never global state.
class DashboardStyleScope extends InheritedWidget {
  const DashboardStyleScope({
    super.key,
    required this.style,
    required super.child,
  });
  final DashboardThemeStyle style;
  static DashboardThemeStyle of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DashboardStyleScope>()
          ?.style ??
      DashboardThemeStyle.soft;
  @override
  bool updateShouldNotify(DashboardStyleScope oldWidget) =>
      style != oldWidget.style;
}

/// Shared surfaces with independent quantitative, control and decorative roles.
class DashboardPalette {
  const DashboardPalette._({
    required this.background,
    required this.panel,
    required this.rail,
    required this.foreground,
    required this.muted,
    required this.border,
    required this.soft,
    required this.dataBlue,
    required this.controlAccent,
    required this.controlFill,
    required this.controlForeground,
    required this.chromeAccent,
    required this.selected,
    required this.reasoning,
    required this.tool,
    required this.danger,
    required this.grid,
  });
  final Color background, panel, rail, foreground, muted;
  final Color border, soft, dataBlue, controlAccent, controlFill;
  final Color controlForeground, chromeAccent, selected, reasoning, tool;
  final Color danger, grid;

  /// Compatibility remains quantitative: API event marks must never turn gold.
  Color get accent => dataBlue;
  Color get chromeGold => chromeAccent;
  static DashboardPalette of(BuildContext context) => forBrightness(
    context.theme.colors.brightness,
    style: DashboardStyleScope.of(context),
  );
  static DashboardPalette forBrightness(
    Brightness brightness, {
    DashboardThemeStyle style = DashboardThemeStyle.soft,
  }) => switch ((style, brightness)) {
    (DashboardThemeStyle.soft, Brightness.light) => _softLight,
    (DashboardThemeStyle.soft, Brightness.dark) => _softDark,
    (DashboardThemeStyle.tech, Brightness.light) => _techLight,
    (DashboardThemeStyle.tech, Brightness.dark) => _techDark,
    (DashboardThemeStyle.graphite, Brightness.light) => _graphiteLight,
    (DashboardThemeStyle.graphite, Brightness.dark) => _graphiteDark,
  };
  static const _softLight = DashboardPalette._(
    background: Color(0xffe6ece8),
    panel: Color(0xfff0f4ef),
    rail: Color(0xffe0e8e3),
    foreground: Color(0xff233b3b),
    muted: Color(0xff536c6a),
    border: Color(0xffbdcbc4),
    soft: Color(0xffe3ebe5),
    dataBlue: Color(0xff326d76),
    controlAccent: Color(0xff326d76),
    controlFill: Color(0xff326d76),
    controlForeground: Color(0xffffffff),
    chromeAccent: Color(0xff77a9ad),
    selected: Color(0xffdfe9e3),
    reasoning: Color(0xff7b64a3),
    tool: Color(0xff3b826d),
    danger: Color(0xffa44657),
    grid: Color(0xffd1ddd6),
  );
  static const _softDark = DashboardPalette._(
    background: Color(0xff141d1d),
    panel: Color(0xff202c2d),
    rail: Color(0xff182323),
    foreground: Color(0xffd9e5e1),
    muted: Color(0xffa5bab5),
    border: Color(0xff405451),
    soft: Color(0xff263637),
    dataBlue: Color(0xff89b7c1),
    controlAccent: Color(0xff89b7c1),
    controlFill: Color(0xff89b7c1),
    controlForeground: Color(0xff182526),
    chromeAccent: Color(0xff9ec9c7),
    selected: Color(0xff2b3b3c),
    reasoning: Color(0xffbba1d3),
    tool: Color(0xff8dbfad),
    danger: Color(0xffe7a1ae),
    grid: Color(0xff344848),
  );
  static const _techLight = DashboardPalette._(
    background: Color(0xffe7ebf3),
    panel: Color(0xfff2f5fa),
    rail: Color(0xffe7ebf3),
    foreground: Color(0xff263b5a),
    muted: Color(0xff576b8b),
    border: Color(0xffbac9e0),
    soft: Color(0xffe8edf6),
    dataBlue: Color(0xff245deb),
    controlAccent: Color(0xff245deb),
    controlFill: Color(0xff245deb),
    controlForeground: Color(0xffffffff),
    chromeAccent: Color(0xff4d7eff),
    selected: Color(0xffe7edf9),
    reasoning: Color(0xff735eaa),
    tool: Color(0xff2a7a70),
    danger: Color(0xffac4057),
    grid: Color(0xffd0daea),
  );
  static const _techDark = DashboardPalette._(
    background: Color(0xff121b2b),
    panel: Color(0xff1e2c40),
    rail: Color(0xff172237),
    foreground: Color(0xffdfe8f7),
    muted: Color(0xffabbcd4),
    border: Color(0xff405779),
    soft: Color(0xff24354c),
    dataBlue: Color(0xff719aff),
    controlAccent: Color(0xff719aff),
    controlFill: Color(0xff719aff),
    controlForeground: Color(0xff111a2b),
    chromeAccent: Color(0xff85a9ff),
    selected: Color(0xff24354c),
    reasoning: Color(0xffbcaff0),
    tool: Color(0xff8bcbbc),
    danger: Color(0xffeda5b4),
    grid: Color(0xff344965),
  );
  static const _graphiteLight = DashboardPalette._(
    background: Color(0xffeae8e3),
    panel: Color(0xfff5f2ec),
    rail: Color(0xffe4e1dc),
    foreground: Color(0xff34332f),
    muted: Color(0xff69645b),
    border: Color(0xffcbc3b6),
    soft: Color(0xffe8e4dd),
    dataBlue: Color(0xff356edf),
    controlAccent: Color(0xff62503b),
    controlFill: Color(0xffd8c195),
    controlForeground: Color(0xff322f2b),
    chromeAccent: Color(0xffd8c195),
    selected: Color(0xffeae3d5),
    reasoning: Color(0xff7b668f),
    tool: Color(0xff487a67),
    danger: Color(0xffa54456),
    grid: Color(0xffd9d2c7),
  );
  static const _graphiteDark = DashboardPalette._(
    background: Color(0xff1b1b1f),
    panel: Color(0xff28282d),
    rail: Color(0xff212125),
    foreground: Color(0xffe9e6e0),
    muted: Color(0xffb7b2aa),
    border: Color(0xff514c44),
    soft: Color(0xff323137),
    dataBlue: Color(0xff7da1ff),
    controlAccent: Color(0xffddc89d),
    controlFill: Color(0xffddc89d),
    controlForeground: Color(0xff27241f),
    chromeAccent: Color(0xffe0cba2),
    selected: Color(0xff3c3832),
    reasoning: Color(0xffbaa5d2),
    tool: Color(0xff96bda9),
    danger: Color(0xffe6a4b0),
    grid: Color(0xff413e3d),
  );
}
