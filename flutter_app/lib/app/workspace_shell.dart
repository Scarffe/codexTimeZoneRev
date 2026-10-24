import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'monitor_presentation.dart';
import 'dashboard_style.dart';
import 'dashboard_motion.dart';

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
    required this.launcher,
    required this.overview,
    required this.accounts,
    required this.sessions,
    required this.analysis,
    required this.benchmark,
    this.unreadCount = 0,
    this.onSettings,
  });
  final WorkspaceDestination selected;
  final int unreadCount;
  final ValueChanged<WorkspaceDestination> onSelect;
  final String appearance;
  final ValueChanged<String> onAppearance;
  final Widget launcher, overview, accounts, sessions, analysis, benchmark;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth <= 620;
      final colors = context.theme.colors;
      final palette = DashboardPalette.of(context);
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
                          ? '${destination.label} · $unreadCount 未读'
                          : destination.label,
                      icon: destination.icon,
                      selected: selected == destination,
                      onPress: () => onSelect(destination),
                    ),
                  const Spacer(),
                  MonitorIconAction(
                    key: const ValueKey('monitor-settings'),
                    label: '监控与提醒设置',
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
                    constraints: const BoxConstraints(minHeight: 52),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.border)),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontal,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              selected.label,
                              style: context.theme.typography.display.xl,
                            ),
                          ),
                        ),
                        FPopoverMenu(
                          menuAnchor: Alignment.topRight,
                          childAnchor: Alignment.bottomRight,
                          menuBuilder: (context, controller, _) => [
                            FItemGroup(
                              children: [
                                for (final (label, value, icon) in [
                                  ('跟随系统', 'system', FLucideIcons.monitor),
                                  ('浅色', 'light', FLucideIcons.sun),
                                  ('深色', 'dark', FLucideIcons.moon),
                                ])
                                  FItem(
                                    title: Text(label),
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
                                label: '主题',
                                icon: appearance == 'dark'
                                    ? FLucideIcons.moon
                                    : appearance == 'light'
                                    ? FLucideIcons.sun
                                    : FLucideIcons.monitor,
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
                                  title: const Text('Codex 时区启动器'),
                                  subtitle: const Text(
                                    '版本 ${String.fromEnvironment('FLUTTER_BUILD_NAME', defaultValue: 'dev')}',
                                  ),
                                  enabled: false,
                                ),
                              ],
                            ),
                          ],
                          builder: (context, controller, _) =>
                              MonitorIconAction(
                                key: const ValueKey('workspace-about'),
                                label: '应用信息',
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
                          color: DashboardPalette.of(context).chromeGold,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  Icon(
                    icon,
                    size: 18,
                    color: selected
                        ? DashboardPalette.of(context).accent
                        : DashboardPalette.of(context).muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
