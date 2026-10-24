import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'dashboard_motion.dart';
import 'dashboard_style.dart';

import '../domain/settings.dart';
import '../services/clocks.dart';
import '../services/desktop_services.dart';
import '../services/network_info.dart';
import '../state/launcher_controller.dart';

class LauncherPage extends StatelessWidget {
  const LauncherPage({
    super.key,
    required this.launcher,
    required this.network,
    this.desktop = const SystemDesktopServices(),
  });
  final LauncherController launcher;
  final NetworkController network;
  final DesktopServices desktop;

  Future<void> _browse() =>
      launcher.browse(() => desktop.chooseClient(launcher.platform));

  Widget _section(
    BuildContext context,
    String title,
    String description,
    List<Widget> children,
  ) => FCard(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: context.theme.typography.display.lg.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final settings = launcher.settings;
    final settingCard = _section(context, '启动设置', '新进程使用此时区，系统时区保持不变。', [
      FSelect<String>(
        label: const Text('设置方式'),
        items: const {'地区时区': 'zone', '固定 UTC 偏移': 'offset'},
        enabled: launcher.editable,
        control: FSelectControl.lifted(
          value: settings.mode,
          onChange: (value) {
            if (value != null) launcher.update(settings.copyWith(mode: value));
          },
        ),
      ),
      const SizedBox(height: 12),
      if (settings.mode == 'zone')
        FSelect<String>.search(
          label: const Text('地区时区'),
          description: const Text('搜索城市或时区；自动遵循当地夏令时。'),
          items: {
            for (final zone in launcher.zones)
              '${zone.label} · ${zone.id}': zone.id,
          },
          enabled: launcher.editable && launcher.zones.isNotEmpty,
          control: FSelectControl.lifted(
            value: launcher.zones.any((zone) => zone.id == settings.zoneId)
                ? settings.zoneId
                : null,
            onChange: (value) {
              if (value != null) {
                launcher.update(settings.copyWith(zoneId: value));
              }
            },
          ),
        )
      else
        FSelect<int>(
          label: const Text('固定 UTC 偏移'),
          description: const Text('不随夏令时变化；半小时地区请使用地区时区。'),
          enabled: launcher.editable,
          items: {for (var i = -12; i <= 14; i++) offsetLabel(i * 60): i},
          control: FSelectControl.lifted(
            value: settings.offset,
            onChange: (value) {
              if (value != null) {
                launcher.update(settings.copyWith(offset: value));
              }
            },
          ),
        ),
      if (launcher.editable && launcher.validationError != null) ...[
        const SizedBox(height: 12),
        FAlert(
          variant: FAlertVariant.destructive,
          title: Text(launcher.validationError!),
        ),
      ],
    ]);
    final clientPath = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PathField(launcher: launcher),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: _motionButton(
            FButton(
              mainAxisSize: MainAxisSize.min,
              variant: FButtonVariant.outline,
              onPress:
                  launcher.editable &&
                      !launcher.preview &&
                      !launcher.offlineTrial
                  ? _browse
                  : null,
              prefix: const Icon(FLucideIcons.folderOpen),
              child: const Text('选择客户端'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          launcher.effectivePath.isEmpty
              ? '未找到客户端，请选择 Codex 程序。'
              : '当前路径：${launcher.effectivePath}',
          style: context.theme.typography.body.sm.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
    final skinControls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FSwitch(
          label: const Text('Dream Skin 兼容启动'),
          description: const Text('保存后，在下次启动时应用皮肤。'),
          value: settings.dreamSkinCompatible,
          enabled: launcher.editable,
          onChange: (value) =>
              launcher.update(settings.copyWith(dreamSkinCompatible: value)),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _motionButton(
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.outline,
                onPress:
                    launcher.editable &&
                        !launcher.preview &&
                        !launcher.offlineTrial
                    ? () => launcher.action('launch_dream_skin')
                    : null,
                child: const Flexible(child: Text('打开 Dream Skin')),
              ),
            ),
            _motionButton(
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.outline,
                onPress:
                    launcher.editable &&
                        !launcher.preview &&
                        !launcher.offlineTrial
                    ? () => launcher.action('reapply_dream_skin')
                    : null,
                child: const Flexible(child: Text('重新注入皮肤')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '重新注入仅适用于兼容启动的客户端；保持当前进程与时区。',
          style: context.theme.typography.body.sm.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
    final clientCard = _section(context, '客户端与皮肤', '选择程序并配置下次启动。', [
      LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                clientPath,
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: FDivider(),
                ),
                skinControls,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: clientPath),
              const SizedBox(width: 32),
              Expanded(flex: 5, child: skinControls),
            ],
          );
        },
      ),
    ]);

    return FScaffold(
      childPad: false,
      footer: Container(
        decoration: BoxDecoration(
          color: DashboardPalette.of(context).panel,
          border: Border(top: BorderSide(color: context.theme.colors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                launcher.message,
                style: context.theme.typography.body.sm,
              ),
            ),
            const SizedBox(height: 12),
            if (launcher.repairPackage != null) ...[
              Text(
                '待修复版本：${launcher.repairPackage}\n仅修复当前版本的启动权限，保留原权限备份；完成后自动重试启动。需要 Windows 管理员确认。',
                style: context.theme.typography.body.sm,
              ),
              if (launcher.repairLogPath != null)
                Text(
                  '启动日志：${launcher.repairLogPath}',
                  style: context.theme.typography.body.sm,
                ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (launcher.repairPackage != null)
                  _motionButton(
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: launcher.canSave
                          ? () => launcher.action('repair_launch')
                          : null,
                      child: Text(
                        launcher.busyCommand == 'repair_launch'
                            ? '正在修复…'
                            : '一键修复并重试',
                      ),
                    ),
                  ),
                _motionButton(
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: launcher.canLaunch
                        ? () => launcher.action('launch')
                        : null,
                    prefix: const Icon(FLucideIcons.play),
                    child: Text(
                      launcher.busyCommand == 'launch' ? '正在启动…' : '保存并启动',
                    ),
                  ),
                ),
                _motionButton(
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.outline,
                    onPress: launcher.canSave
                        ? () => launcher.action('save')
                        : null,
                    child: const Text('保存设置'),
                  ),
                ),
                _motionButton(
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.ghost,
                    onPress: launcher.editable && !launcher.preview
                        ? () => launcher.action('create_shortcut')
                        : null,
                    child: const Text('创建快捷方式'),
                  ),
                ),
                if (launcher.dirty) FBadge(child: const Text('未保存修改')),
                if (launcher.preview) FBadge(child: const Text('演示模式')),
              ],
            ),
          ],
        ),
      ),
      child: SingleChildScrollView(
        key: const PageStorageKey('launcher-scroll'),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (launcher.initializing || launcher.busy) ...[
                  const FProgress(),
                  const SizedBox(height: 16),
                ],
                if (launcher.error != null) ...[
                  FAlert(
                    variant: FAlertVariant.destructive,
                    title: Text(launcher.message),
                    subtitle: Text(launcher.error!),
                  ),
                  const SizedBox(height: 12),
                ],
                if (launcher.bootstrapFailed) ...[
                  _motionButton(
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: launcher.initialize,
                      child: const Text('重新读取设置'),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final clock = ClockPanel(
                      settings: settings,
                      preview: launcher.preview,
                    );
                    if (constraints.maxWidth < 820) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          clock,
                          const SizedBox(height: 16),
                          settingCard,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: clock),
                        const SizedBox(width: 16),
                        Expanded(flex: 6, child: settingCard),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                clientCard,
                const SizedBox(height: 16),
                _section(
                  context,
                  '网络位置参考',
                  network.cached ? '上次查询结果 · 更新中' : '国内 / 国际独立查询 · 应用时区仅写入草稿',
                  [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _motionButton(
                        FButton(
                          mainAxisSize: MainAxisSize.min,
                          variant: FButtonVariant.outline,
                          onPress:
                              network.busy ||
                                  network.offlineTrial ||
                                  launcher.preview ||
                                  launcher.busy
                              ? null
                              : network.refresh,
                          prefix: const Icon(FLucideIcons.refreshCw),
                          child: Text(network.busy ? '正在查询…' : '刷新网络信息'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final domestic = _NetworkRegion(
                          desktop: desktop,
                          title: '国内线路',
                          info: network.domestic,
                          error: network.errors['domestic'],
                          busy: network.busy,
                          launcher: launcher,
                        );
                        final international = _NetworkRegion(
                          desktop: desktop,
                          title: '国际线路',
                          info: network.international,
                          error: network.errors['international'],
                          busy: network.busy,
                          launcher: launcher,
                        );
                        if (constraints.maxWidth < 650) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              domestic,
                              const SizedBox(height: 16),
                              international,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: domestic),
                            const SizedBox(width: 12),
                            Expanded(child: international),
                          ],
                        );
                      },
                    ),
                    if (network.errors['cache'] != null)
                      Text(network.errors['cache']!),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '启动前请完全退出正在运行的 Codex。本工具不会更改系统全局时区。',
                  style: context.theme.typography.body.sm.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PathField extends StatefulWidget {
  const _PathField({required this.launcher});
  final LauncherController launcher;
  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final controller = TextEditingController(
    text: widget.launcher.settings.executable,
  );
  @override
  void didUpdateWidget(covariant _PathField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.launcher.settings.executable;
    if (controller.text != text) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) => FTextField(
    label: const Text('客户端路径'),
    hint: '留空时自动查找 Codex',
    control: FTextFieldControl.managed(
      controller: controller,
      onChange: (value) {
        if (value.text != widget.launcher.settings.executable) {
          widget.launcher.update(
            widget.launcher.settings.copyWith(executable: value.text),
          );
        }
      },
    ),
    enabled: widget.launcher.editable,
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

class ClockPanel extends StatefulWidget {
  const ClockPanel({
    super.key,
    required this.settings,
    required this.preview,
    this.compact = false,
  });
  final LauncherSettings settings;
  final bool preview;
  final bool compact;
  @override
  State<ClockPanel> createState() => _ClockPanelState();
}

class _ClockPanelState extends State<ClockPanel> with WidgetsBindingObserver {
  Timer? _timer;
  bool _active = true, _resumed = true;
  late DateTime _now = widget.preview
      ? DateTime.utc(2026, 9, 22, 1, 24, 8)
      : DateTime.now();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.valuesOf(context).enabled;
    if (_active && !widget.preview) _now = DateTime.now();
    _start();
  }

  void _start() {
    _timer?.cancel();
    if (!widget.preview && _active && _resumed) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() => _now = DateTime.now()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _resumed = false;
      _timer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _resumed = true;
      setState(() => _now = DateTime.now());
      _start();
    }
  }

  @override
  Widget build(BuildContext context) {
    ClockReading? target;
    try {
      target = targetClock(widget.settings, _now);
    } catch (_) {
      /* Unsupported zone remains visibly invalid. */
    }
    final local = widget.preview
        ? targetClock(const LauncherSettings(), _now)
        : ClockReading.fromDate(_now.toLocal());
    final palette = DashboardPalette.of(context);
    final muted = context.theme.typography.body.sm.copyWith(
      color: palette.muted,
    );
    return FCard(
      key: const ValueKey('time-preview-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  FLucideIcons.clock3,
                  size: 18,
                  color: palette.controlAccent,
                ),
                const SizedBox(width: 8),
                Text('时间预览', style: context.theme.typography.display.lg),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              widget.settings.mode == 'zone' ? widget.settings.zoneId : '固定偏移',
              style: muted,
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                target?.time ?? '--:--:--',
                style: context.theme.typography.display.xl.copyWith(
                  fontSize: widget.compact ? 46 : 56,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(target?.date ?? '请选择有效时区', style: muted),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FBadge(child: Text(target?.offset ?? '无效时区')),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: FDivider(),
            ),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '本地时间 · ${widget.preview ? 'Asia/Shanghai' : _now.toLocal().timeZoneName}',
                      style: muted,
                    ),
                    const SizedBox(height: 4),
                    Text(local.date, style: muted),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      local.time,
                      style: context.theme.typography.display.lg.copyWith(
                        fontSize: 22,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(local.offset, style: muted),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _NetworkRegion extends StatefulWidget {
  const _NetworkRegion({
    required this.desktop,
    required this.title,
    required this.info,
    required this.error,
    required this.busy,
    required this.launcher,
  });
  final String title;
  final IpInfo? info;
  final String? error;
  final bool busy;
  final LauncherController launcher;
  final DesktopServices desktop;
  @override
  State<_NetworkRegion> createState() => _NetworkRegionState();
}

class _NetworkRegionState extends State<_NetworkRegion> {
  String copyLabel = '复制 IP';
  Timer? _timer;
  Future<void> _copy() async {
    final ip = widget.info!.ip;
    try {
      await widget.desktop.copyVerified(ip);
      if (mounted) setState(() => copyLabel = '已复制');
    } catch (e) {
      if (mounted) {
        setState(() => copyLabel = '复制失败');
        widget.launcher.report('无法复制 IP。', detail: e.toString());
      }
    }
    _timer?.cancel();
    if (mounted) {
      _timer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => copyLabel = '复制 IP');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final supported =
        info != null &&
        widget.launcher.zones.any((zone) => zone.id == info.timezone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.title,
          style: context.theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        if (info == null)
          Text(
            widget.busy ? '正在查询公网 IP 与位置…' : widget.error ?? '暂无网络信息',
            style: context.theme.typography.body.sm,
          )
        else ...[
          Text(info.ip, style: context.theme.typography.display.lg),
          const SizedBox(height: 6),
          Text(info.location, style: context.theme.typography.body.sm),
          Text(info.organization, style: context.theme.typography.body.sm),
          const SizedBox(height: 6),
          Text(
            '${info.timezone} · ${info.source}',
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _motionButton(
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.outline,
                  onPress: widget.launcher.preview || widget.launcher.busy
                      ? null
                      : _copy,
                  child: Text(copyLabel),
                ),
              ),
              _motionButton(
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.ghost,
                  onPress: supported && widget.launcher.editable
                      ? () {
                          widget.launcher.update(
                            widget.launcher.settings.copyWith(
                              mode: 'zone',
                              zoneId: info.timezone,
                            ),
                          );
                          widget.launcher.report(
                            '已选择 ${info.timezone}，保存并启动后生效。',
                          );
                        }
                      : null,
                  child: Text(supported ? '应用识别时区' : '暂不支持此时区'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

Widget _motionButton(FButton button) =>
    DashboardMotionFeedback(enabled: button.onPress != null, child: button);
