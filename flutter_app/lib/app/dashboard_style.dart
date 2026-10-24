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
    background: Color(0xffe8ecea),
    panel: Color(0xfff0f3f0),
    rail: Color(0xffe0e6e3),
    foreground: Color(0xff273b3d),
    muted: Color(0xff53676a),
    border: Color(0xffc6d1cd),
    soft: Color(0xffe0e8e4),
    accent: Color(0xff356d7d),
    selected: Color(0xffd6e3e5),
    reasoning: Color(0xff7b64a3),
    tool: Color(0xff3b826d),
    danger: Color(0xffad5060),
    grid: Color(0xffdae2de),
  );
  static const _dark = DashboardPalette._(
    background: Color(0xff192125),
    panel: Color(0xff232d31),
    rail: Color(0xff1c262a),
    foreground: Color(0xffd5e0df),
    muted: Color(0xffa6b7b4),
    border: Color(0xff40504f),
    soft: Color(0xff2e3d40),
    accent: Color(0xff8ab7c5),
    selected: Color(0xff31484f),
    reasoning: Color(0xffbba1d3),
    tool: Color(0xff8dbfad),
    danger: Color(0xffe7a1ae),
    grid: Color(0xff354347),
  );
}
