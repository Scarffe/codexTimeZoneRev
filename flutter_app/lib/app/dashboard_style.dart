import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Shared colors for the compact dashboard and its data series.
/// Interactive Forui surfaces use the same opaque colors in launcherTheme.
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
    required this.chromeGold,
    required this.selected,
    required this.reasoning,
    required this.tool,
    required this.danger,
    required this.grid,
  });

  final Color background, panel, rail, foreground, muted, border, soft;
  final Color dataBlue, chromeGold, selected, reasoning, tool, danger, grid;

  /// Compatibility for semantic controls and existing quantitative callers.
  /// Decorative chrome uses [chromeGold] explicitly, never small light text.
  Color get accent => dataBlue;

  static DashboardPalette of(BuildContext context) =>
      forBrightness(context.theme.colors.brightness);

  static DashboardPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static const _light = DashboardPalette._(
    background: Color(0xffe7ebf1),
    panel: Color(0xfff1f3f6),
    rail: Color(0xffdfe5ed),
    foreground: Color(0xff253046),
    muted: Color(0xff506078),
    border: Color(0xffc4cddd),
    soft: Color(0xffe0e6ef),
    dataBlue: Color(0xff2459eb),
    chromeGold: Color(0xffd6ba84),
    selected: Color(0xffdce5fa),
    reasoning: Color(0xff7b64a3),
    tool: Color(0xff3b826d),
    danger: Color(0xffad5060),
    grid: Color(0xffd5dde9),
  );
  static const _dark = DashboardPalette._(
    background: Color(0xff111723),
    panel: Color(0xff1a2232),
    rail: Color(0xff151d2b),
    foreground: Color(0xffe0e7f3),
    muted: Color(0xffa7b6cf),
    border: Color(0xff3b4962),
    soft: Color(0xff263248),
    dataBlue: Color(0xff5987ff),
    chromeGold: Color(0xffe6ca93),
    selected: Color(0xff283b61),
    reasoning: Color(0xffbba1d3),
    tool: Color(0xff8dbfad),
    danger: Color(0xffe7a1ae),
    grid: Color(0xff303e56),
  );
}
