import 'package:forui/forui.dart';

// Build dependent component styles from a single desktop type scale, including
// explicit CJK fallbacks instead of relying on platform font discovery alone.
FThemeData launcherTheme(bool dark, {bool acrylic = false}) {
  final base =
      (dark ? FTheme.neutral.dark.desktop : FTheme.neutral.light.desktop)
          .colors;
  final colors = acrylic
      ? base.copyWith(card: base.card.withValues(alpha: dark ? 0.48 : 0.54))
      : base;
  final typeface = FTypeface.inherit(
    colors: colors,
    touch: false,
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
    ],
  );
  final theme = FThemeData(
    colors: colors,
    touch: false,
    typography: FTypography(display: typeface, body: typeface),
  );
  // Only the page backdrop is transparent. Menus and input surfaces retain
  // their opaque fill so desktop content cannot reduce their readability.
  return acrylic
      ? theme.copyWith(
          scaffoldStyle: theme.scaffoldStyle.copyWith(
            backgroundColor: base.background.withValues(alpha: 0),
          ),
        )
      : theme;
}

final lightLauncherTheme = launcherTheme(false);
final darkLauncherTheme = launcherTheme(true);
final lightAcrylicTheme = launcherTheme(false, acrylic: true);
final darkAcrylicTheme = launcherTheme(true, acrylic: true);
