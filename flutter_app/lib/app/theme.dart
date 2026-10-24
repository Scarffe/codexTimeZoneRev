import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'dashboard_style.dart';

// Build dependent component styles from a single desktop type scale, including
// explicit CJK fallbacks instead of relying on platform font discovery alone.
final _themes = <(bool, bool, DashboardThemeStyle), FThemeData>{};

FThemeData launcherTheme(
  bool dark, {
  bool acrylic = false,
  DashboardThemeStyle style = DashboardThemeStyle.soft,
}) => _themes.putIfAbsent((
  dark,
  acrylic,
  style,
), () => _buildLauncherTheme(dark, acrylic: acrylic, style: style));

FThemeData _buildLauncherTheme(
  bool dark, {
  required bool acrylic,
  required DashboardThemeStyle style,
}) {
  final base =
      (dark ? FTheme.neutral.dark.desktop : FTheme.neutral.light.desktop)
          .colors;
  // Forui also uses card for select popovers and text fields. Keep this shared
  // token opaque and apply the acrylic tint only to the page's card surfaces.
  final palette = DashboardPalette.forBrightness(base.brightness, style: style);
  final colors = base.copyWith(
    background: palette.background,
    foreground: palette.foreground,
    // Forui reuses primary for item icons and focus/switch strokes.
    // Pale champagne belongs only to filled actions, never those small marks.
    primary: palette.controlAccent,
    primaryForeground: dark
        ? palette.controlForeground
        : const Color(0xffffffff),
    secondary: palette.selected,
    secondaryForeground: palette.controlAccent,
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
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Segoe UI',
      'PingFang SC',
      'Noto Sans CJK SC',
    ],
  );
  TextStyle text(double size, {FontWeight weight = FontWeight.w400}) =>
      inherited.md.copyWith(fontSize: size, height: 1.5, fontWeight: weight);
  final typeface = inherited.copyWith(
    xs3: text(11),
    xs2: text(11),
    xs: text(12),
    sm: text(13),
    md: text(14),
    lg: text(15, weight: FontWeight.w500),
    xl: text(22, weight: FontWeight.w600),
    xl2: text(24, weight: FontWeight.w600),
  );
  final typography = FTypography(display: typeface, body: typeface);
  final componentStyle =
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
  FButtonStyles buttons(FColors buttonColors) => FButtonStyles.inherit(
    colors: buttonColors,
    typography: typography,
    style: componentStyle,
    touch: false,
  );
  final filledColors = colors.copyWith(
    primary: palette.controlFill,
    primaryForeground: palette.controlForeground,
    // Default HSL lightening drops Soft light white text below 4.5 on hover.
    // Keep a visible change while preserving the action's readable contrast.
    hoverLighten: !dark && style == DashboardThemeStyle.soft
        ? 0.03
        : colors.hoverLighten,
  );
  final inheritedButtons = buttons(filledColors);
  // Secondary hover changes its fill again; body text stays readable there.
  // Destructive buttons need a solid fill rather than same-hue tinted text.
  final secondaryButtons = buttons(
    filledColors.copyWith(secondaryForeground: palette.foreground),
  ).secondary;
  final destructiveButtons = buttons(
    colors.copyWith(
      primary: palette.danger,
      primaryForeground: colors.destructiveForeground,
      hoverLighten: dark ? colors.hoverLighten : 0.02,
    ),
  ).primary;
  final theme = FThemeData(
    colors: colors,
    touch: false,
    typography: typography,
    style: componentStyle,
    buttonStyles: FButtonStyles(
      FVariants.raw(inheritedButtons.base, {
        ...inheritedButtons.variants,
        FButtonVariant.secondary: secondaryButtons,
        FButtonVariant.destructive: destructiveButtons,
      }),
    ),
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
