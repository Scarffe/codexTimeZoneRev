import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'monitor_presentation.dart';
import 'dashboard_style.dart';
import 'dashboard_motion.dart';
import '../l10n/app_copy.dart';
import '../l10n/app_language.dart';

enum WorkspaceDestination {
  launcher('启动器', FLucideIcons.clock3),
  overview('总览', FLucideIcons.layoutDashboard),
  accounts('账号额度', FLucideIcons.users),
  sessions('关注与收件箱', FLucideIcons.inbox),
  analysis('数据分析', FLucideIcons.chartNoAxesCombined),
  benchmark('独立 API 测速', FLucideIcons.gauge);

  const WorkspaceDestination(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Navigation changes visibility, never controller or page ownership.
class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.appearance,
    required this.onAppearance,
    this.themeStyle = DashboardThemeStyle.soft,
    this.onThemeStyle,
    required this.launcher,
    required this.overview,
    required this.accounts,
    required this.sessions,
    required this.analysis,
    required this.benchmark,
    this.unreadCount = 0,
    this.onSettings,
    this.language = AppLanguage.zh,
    this.onLanguage,
  });
  final WorkspaceDestination selected;
  final int unreadCount;
  final ValueChanged<WorkspaceDestination> onSelect;
  final String appearance;
  final ValueChanged<String> onAppearance;
  final DashboardThemeStyle themeStyle;
  final ValueChanged<DashboardThemeStyle>? onThemeStyle;
  final Widget launcher, overview, accounts, sessions, analysis, benchmark;
  final VoidCallback? onSettings;
  final AppLanguage language;
  final ValueChanged<AppLanguage>? onLanguage;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth <= 620;
      final colors = context.theme.colors;
      final palette = DashboardPalette.of(context);
      final copy = AppCopy.of(context);
      final horizontal = narrow
          ? 12.0
          : constraints.maxWidth <= 760
          ? 16.0
          : 22.0;
      return FScaffold(
        childPad: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const ValueKey('workspace-rail'),
              width: narrow ? 45 : 56,
              decoration: BoxDecoration(
                color: palette.rail,
                border: Border(right: BorderSide(color: colors.border)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  for (final destination in WorkspaceDestination.values)
                    _RailEntry(
                      key: ValueKey('workspace-${destination.name}'),
                      name:
                          destination == WorkspaceDestination.sessions &&
                              unreadCount > 0
                          ? copy.text(
                              'nav.unread',
                              args: {
                                'name': copy.text('nav.${destination.name}'),
                                'count': unreadCount,
                              },
                            )
                          : copy.text('nav.${destination.name}'),
                      icon: destination.icon,
                      selected: selected == destination,
                      onPress: () => onSelect(destination),
                    ),
                  const Spacer(),
                  MonitorIconAction(
                    key: const ValueKey('monitor-settings'),
                    label: copy.text('app.monitorSettings'),
                    icon: FLucideIcons.settings,
                    onPress: onSettings,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    constraints: BoxConstraints(minHeight: narrow ? 62 : 78),
                    decoration: BoxDecoration(
                      color: palette.panel.withValues(alpha: .45),
                      border: Border(bottom: BorderSide(color: colors.border)),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontal,
                      vertical: narrow ? 8 : 11,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!narrow)
                                  Text(
                                    'CODEX TIMEZONE',
                                    style: context.theme.typography.body.xs
                                        .copyWith(
                                          color: palette.muted,
                                          fontSize: 10,
                                          height: 1.2,
                                          letterSpacing: 1.7,
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                if (!narrow) const SizedBox(height: 3),
                                Text(
                                  copy.text('nav.${selected.name}'),
                                  style: context.theme.typography.display.xl
                                      .copyWith(
                                        height: 1.2,
                                        letterSpacing: -.4,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        FPopoverMenu(
                          menuAnchor: Alignment.topRight,
                          childAnchor: Alignment.bottomRight,
                          menuBuilder: (context, controller, _) => [
                            FItemGroup(
                              semanticsLabel: copy.text('theme.family'),
                              children: [
                                FItem(
                                  title: Text(copy.text('theme.family')),
                                  enabled: false,
                                ),
                                for (final style in DashboardThemeStyle.values)
                                  FItem(
                                    key: ValueKey('theme-style-${style.id}'),
                                    title: Text(copy.text('theme.${style.id}')),
                                    suffix: themeStyle == style
                                        ? const Icon(FLucideIcons.check)
                                        : null,
                                    onPress: onThemeStyle == null
                                        ? null
                                        : () {
                                            onThemeStyle!(style);
                                            controller.hide();
                                          },
                                  ),
                              ],
                            ),
                            FItemGroup(
                              children: [
                                FItem(
                                  title: Text(copy.text('theme.mode')),
                                  enabled: false,
                                ),
                                for (final (_, value, icon) in [
                                  ('跟随系统', 'system', FLucideIcons.monitor),
                                  ('浅色', 'light', FLucideIcons.sun),
                                  ('深色', 'dark', FLucideIcons.moon),
                                ])
                                  FItem(
                                    title: Text(copy.text('theme.$value')),
                                    prefix: Icon(icon),
                                    suffix: appearance == value
                                        ? const Icon(FLucideIcons.check)
                                        : null,
                                    onPress: () {
                                      onAppearance(value);
                                      controller.hide();
                                    },
                                  ),
                              ],
                            ),
                          ],
                          builder: (context, controller, _) =>
                              MonitorIconAction(
                                key: const ValueKey('workspace-theme'),
                                label: copy.text('theme.menu'),
                                icon: appearance == 'dark'
                                    ? FLucideIcons.moon
                                    : appearance == 'light'
                                    ? FLucideIcons.sun
                                    : FLucideIcons.monitor,
                                onPress: controller.toggle,
                              ),
                        ),
                        if (onLanguage != null)
                          FPopoverMenu(
                            menuAnchor: Alignment.topRight,
                            childAnchor: Alignment.bottomRight,
                            menuBuilder: (context, controller, _) => [
                              FItemGroup(
                                children: [
                                  for (final choice in AppLanguage.values)
                                    FItem(
                                      key: ValueKey('language-${choice.code}'),
                                      title: Text(
                                        copy.text(
                                          'app.language.${choice.code}',
                                        ),
                                      ),
                                      suffix: language == choice
                                          ? const Icon(FLucideIcons.check)
                                          : null,
                                      onPress: () {
                                        onLanguage!(choice);
                                        controller.hide();
                                      },
                                    ),
                                ],
                              ),
                            ],
                            builder: (context, controller, _) =>
                                MonitorIconAction(
                                  key: const ValueKey('workspace-language'),
                                  label: copy.text('app.language'),
                                  icon: FLucideIcons.languages,
                                  onPress: controller.toggle,
                                ),
                          ),
                        FPopoverMenu(
                          menuAnchor: Alignment.topRight,
                          childAnchor: Alignment.bottomRight,
                          menu: [
                            FItemGroup(
                              children: [
                                FItem(
                                  title: Text(copy.text('app.name')),
                                  subtitle: Text(
                                    copy.text(
                                      'app.version',
                                      args: {
                                        'version': const String.fromEnvironment(
                                          'FLUTTER_BUILD_NAME',
                                          defaultValue: 'dev',
                                        ),
                                      },
                                    ),
                                  ),
                                  enabled: false,
                                ),
                              ],
                            ),
                          ],
                          builder: (context, controller, _) =>
                              MonitorIconAction(
                                key: const ValueKey('workspace-about'),
                                label: copy.text('app.about'),
                                icon: FLucideIcons.info,
                                glyph: Image.asset(
                                  'assets/app_icon.png',
                                  key: const ValueKey('workspace-brand-mark'),
                                  width: 28,
                                  height: 28,
                                  excludeFromSemantics: true,
                                ),
                                onPress: controller.toggle,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontal,
                        narrow ? 15 : horizontal,
                        horizontal,
                        0,
                      ),
                      child: IndexedStack(
                        index: selected.index,
                        children: [
                          for (final (index, page) in [
                            launcher,
                            overview,
                            accounts,
                            sessions,
                            analysis,
                            benchmark,
                          ].indexed)
                            TickerMode(
                              enabled: selected.index == index,
                              child: ExcludeFocus(
                                excluding: selected.index != index,
                                child: page,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _RailEntry extends StatelessWidget {
  const _RailEntry({
    super.key,
    required this.name,
    required this.icon,
    required this.selected,
    required this.onPress,
  });
  final String name;
  final IconData icon;
  final bool selected;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      selected: selected,
      child: FTooltip(
        tipAnchor: Alignment.centerLeft,
        childAnchor: Alignment.centerRight,
        tipBuilder: (context, _) => Text(name),
        child: DashboardMotionFeedback(
          child: FButton.raw(
            semanticsLabel: name,
            semanticsTooltip: name,
            selected: selected,
            variant: FButtonVariant.ghost,
            onPress: onPress,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Container(
                decoration: BoxDecoration(
                  color: selected
                      ? DashboardPalette.of(context).selected
                      : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (selected)
                      Positioned(
                        left: 2,
                        top: 12,
                        bottom: 12,
                        child: Container(
                          width: 3,
                          decoration: BoxDecoration(
                            color: DashboardPalette.of(context).chromeAccent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    Icon(
                      icon,
                      size: 18,
                      color: selected
                          ? DashboardPalette.of(context).controlAccent
                          : DashboardPalette.of(context).muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
