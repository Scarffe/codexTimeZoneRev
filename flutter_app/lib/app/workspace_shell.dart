import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'monitor_presentation.dart';

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
      final narrow = constraints.maxWidth < 600;
      final colors = context.theme.colors;
      return FScaffold(
        childPad: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const ValueKey('workspace-rail'),
              width: narrow ? 56 : 72,
              decoration: BoxDecoration(
                color: colors.card,
                border: Border(right: BorderSide(color: colors.border)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Column(
                children: [
                  _RailEntry(
                    key: const ValueKey('workspace-launcher'),
                    label: narrow ? '启动' : '启动器',
                    name: '时区启动器',
                    icon: FLucideIcons.clock3,
                    selected: !monitorSelected,
                    onPress: () => onSelect(false),
                  ),
                  const SizedBox(height: 8),
                  _RailEntry(
                    key: const ValueKey('workspace-monitor'),
                    label: '监控',
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
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.border)),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: narrow ? 8 : 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Codex 时区启动器',
                                style: context.theme.typography.body.md
                                    .copyWith(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                monitorSelected ? '监控与工具' : '时区启动器',
                                style: context.theme.typography.body.sm
                                    .copyWith(color: colors.mutedForeground),
                              ),
                            ],
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
                        narrow ? 8 : 20,
                        16,
                        narrow ? 8 : 20,
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
    required this.label,
    required this.name,
    required this.icon,
    required this.selected,
    required this.onPress,
  });
  final String label, name;
  final IconData icon;
  final bool selected;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) => FTooltip(
    tipAnchor: Alignment.centerLeft,
    childAnchor: Alignment.centerRight,
    tipBuilder: (context, _) => Text(name),
    child: FButton.raw(
      semanticsLabel: name,
      selected: selected,
      variant: selected ? FButtonVariant.secondary : FButtonVariant.ghost,
      onPress: onPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: context.theme.typography.body.sm.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 12,
                    height: 2,
                    color: context.theme.colors.foreground,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
