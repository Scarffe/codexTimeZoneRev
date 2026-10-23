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
    required this.accent,
    required this.selected,
    required this.reasoning,
    required this.tool,
    required this.danger,
    required this.grid,
  });

  final Color background, panel, rail, foreground, muted, border, soft;
  final Color accent, selected, reasoning, tool, danger, grid;

  static DashboardPalette of(BuildContext context) =>
      forBrightness(context.theme.colors.brightness);

  static DashboardPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static const _light = DashboardPalette._(
    background: Color(0xfff5f6f8),
    panel: Color(0xffffffff),
    rail: Color(0xffeef0f3),
    foreground: Color(0xff202833),
    muted: Color(0xff596677),
    border: Color(0xffdce1e7),
    soft: Color(0xffedf1f5),
    accent: Color(0xff345eaf),
    selected: Color(0xffe8eefb),
    reasoning: Color(0xff92724b),
    tool: Color(0xff4b8378),
    danger: Color(0xffb54444),
    grid: Color(0xffe9edf2),
  );
  static const _dark = DashboardPalette._(
    background: Color(0xff14171c),
    panel: Color(0xff1d2229),
    rail: Color(0xff181c22),
    foreground: Color(0xffe4e9f0),
    muted: Color(0xffa7b1bf),
    border: Color(0xff353c47),
    soft: Color(0xff272e38),
    accent: Color(0xff92b7ff),
    selected: Color(0xff283a58),
    reasoning: Color(0xffd3b58b),
    tool: Color(0xff8cc4b4),
    danger: Color(0xfff3a1a1),
    grid: Color(0xff303743),
  );
}
