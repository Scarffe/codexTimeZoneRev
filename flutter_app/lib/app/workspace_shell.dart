import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

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
  });
  final bool monitorSelected;
  final ValueChanged<bool> onSelect;
  final String appearance;
  final ValueChanged<String> onAppearance;
  final Widget launcher, monitor;

  @override
  Widget build(BuildContext context) => FScaffold(
    header: Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset(
                'assets/app_icon.png',
                width: 40,
                height: 40,
                excludeFromSemantics: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Codex 时区启动器',
                      style: context.theme.typography.display.lg,
                    ),
                    Text(
                      '独立时区 · 本地启动 · v${const String.fromEnvironment('FLUTTER_BUILD_NAME', defaultValue: 'dev')}',
                      style: context.theme.typography.body.sm,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 138,
                child: FSelect<String>(
                  items: const {'跟随系统': 'system', '浅色': 'light', '深色': 'dark'},
                  control: FSelectControl.lifted(
                    value: appearance,
                    onChange: (value) {
                      if (value != null) onAppearance(value);
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FButton(
                key: const ValueKey('workspace-launcher'),
                mainAxisSize: MainAxisSize.min,
                variant: monitorSelected
                    ? FButtonVariant.outline
                    : FButtonVariant.primary,
                onPress: () => onSelect(false),
                child: const Text('时区启动器'),
              ),
              FButton(
                key: const ValueKey('workspace-monitor'),
                mainAxisSize: MainAxisSize.min,
                variant: monitorSelected
                    ? FButtonVariant.primary
                    : FButtonVariant.outline,
                onPress: () => onSelect(true),
                child: const Text('监控与工具'),
              ),
            ],
          ),
        ],
      ),
    ),
    child: IndexedStack(
      index: monitorSelected ? 1 : 0,
      children: [
        TickerMode(enabled: !monitorSelected, child: launcher),
        TickerMode(enabled: monitorSelected, child: monitor),
      ],
    ),
  );
}
