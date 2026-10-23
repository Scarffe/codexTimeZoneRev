import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'dashboard_style.dart';

// Build dependent component styles from a single desktop type scale, including
// explicit CJK fallbacks instead of relying on platform font discovery alone.
FThemeData launcherTheme(bool dark, {bool acrylic = false}) {
  final base =
      (dark ? FTheme.neutral.dark.desktop : FTheme.neutral.light.desktop)
          .colors;
  // Forui also uses card for select popovers and text fields. Keep this shared
  // token opaque and apply the acrylic tint only to the page's card surfaces.
  final palette = DashboardPalette.forBrightness(base.brightness);
  final colors = base.copyWith(
    background: palette.background,
    foreground: palette.foreground,
    primary: palette.accent,
    primaryForeground: dark ? palette.background : palette.panel,
    secondary: palette.selected,
    secondaryForeground: palette.accent,
    muted: palette.soft,
    mutedForeground: palette.muted,
    card: palette.panel,
    border: palette.border,
    destructive: palette.danger,
    destructiveForeground: dark ? palette.background : palette.panel,
    error: palette.danger,
    errorForeground: dark ? palette.background : palette.panel,
  );
  final inherited = FTypeface.inherit(
    colors: colors,
    touch: false,
    fontFamily: 'Segoe UI Variable Text',
    fontFamilyFallback: const [
      'Segoe UI',
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
    ],
  );
  TextStyle text(double size, {FontWeight weight = FontWeight.w400}) =>
      inherited.md.copyWith(
        fontSize: size,
        height: 1.4,
        fontWeight: weight,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
  final typeface = inherited.copyWith(
    xs3: text(11),
    xs2: text(11),
    xs: text(11),
    sm: text(12),
    md: text(13),
    lg: text(14, weight: FontWeight.w600),
    xl: text(22, weight: FontWeight.w600),
    xl2: text(24, weight: FontWeight.w600),
  );
  final typography = FTypography(display: typeface, body: typeface);
  final style =
      FStyle.inherit(
        colors: colors,
        typography: typography,
        touch: false,
      ).copyWith(
        borderRadius: const FBorderRadius(
          sm: BorderRadius.all(Radius.circular(7)),
          md: BorderRadius.all(Radius.circular(7)),
          lg: BorderRadius.all(Radius.circular(7)),
        ),
        shadow: const [],
        iconStyle: IconThemeDataDelta.delta(
          color: palette.foreground,
          size: 18,
        ),
      );
  final theme = FThemeData(
    colors: colors,
    touch: false,
    typography: typography,
    style: style,
  );
  // The page backdrop and cards reveal the native material; menus and enabled
  // input surfaces retain their opaque fill above the page content.
  return acrylic
      ? theme.copyWith(
          scaffoldStyle: theme.scaffoldStyle.copyWith(
            backgroundColor: palette.background.withValues(alpha: 0),
          ),
          cardStyle: theme.cardStyle.copyWith(
            decoration: DecorationDelta.shapeDelta(
              color: palette.panel.withValues(alpha: dark ? 0.48 : 0.54),
            ),
          ),
        )
      : theme;
}

final lightLauncherTheme = launcherTheme(false);
final darkLauncherTheme = launcherTheme(true);
final lightAcrylicTheme = launcherTheme(false, acrylic: true);
final darkAcrylicTheme = launcherTheme(true, acrylic: true);
