import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'monitor_presentation.dart';
import 'dashboard_style.dart';

/// Keeps both workspaces mounted; navigation changes visibility, never ownership.
class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({
    super.key,
    required this.monitorSelected,
    required this.onSelect,
    required this.appearance,
    required this.onAppearance,
    required this.launcher,
    required this.monitor,
    this.onSettings,
  });
  final bool monitorSelected;
  final ValueChanged<bool> onSelect;
  final String appearance;
  final ValueChanged<String> onAppearance;
  final Widget launcher, monitor;
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
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 3),
              child: Column(
                children: [
                  _RailEntry(
                    key: const ValueKey('workspace-launcher'),
                    name: '时区启动器',
                    icon: FLucideIcons.clock3,
                    selected: !monitorSelected,
                    onPress: () => onSelect(false),
                  ),
                  const SizedBox(height: 8),
                  _RailEntry(
                    key: const ValueKey('workspace-monitor'),
                    name: '监控与工具',
                    icon: FLucideIcons.activity,
                    selected: monitorSelected,
                    onPress: () => onSelect(true),
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
                              monitorSelected ? '监控总览' : '启动器',
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
                                label: '应用信息',
                                icon: FLucideIcons.info,
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
                        index: monitorSelected ? 1 : 0,
                        children: [
                          TickerMode(
                            enabled: !monitorSelected,
                            child: ExcludeFocus(
                              excluding: monitorSelected,
                              child: launcher,
                            ),
                          ),
                          TickerMode(
                            enabled: monitorSelected,
                            child: ExcludeFocus(
                              excluding: !monitorSelected,
                              child: monitor,
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
        child: FButton.raw(
          semanticsLabel: name,
          semanticsTooltip: name,
          selected: selected,
          variant: FButtonVariant.ghost,
          onPress: onPress,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              icon,
              size: 18,
              color: selected
                  ? DashboardPalette.of(context).accent
                  : DashboardPalette.of(context).muted,
            ),
          ),
        ),
      ),
    ),
  );
}
