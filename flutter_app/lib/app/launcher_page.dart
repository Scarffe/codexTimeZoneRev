import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:timezone/timezone.dart' as tz;

import '../l10n/app_copy.dart';
import '../l10n/copy_launcher.dart';

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
      padding: const EdgeInsets.all(16),
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
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
    final settings = launcher.settings;
    final settingCard = _section(
      context,
      copy.text('launcher.settings'),
      copy.text('launcher.settingsDescription'),
      [
        LayoutBuilder(
          builder: (context, constraints) {
            final sideBySide = constraints.maxWidth >= 560;
            final modeWidth = sideBySide ? 180.0 : constraints.maxWidth;
            final zoneWidth = sideBySide
                ? constraints.maxWidth - modeWidth - 12
                : constraints.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: modeWidth,
                  child: FSelect<String>(
                    key: const ValueKey('launcher-mode'),
                    label: Text(copy.text('launcher.mode')),
                    items: {
                      copy.text('launcher.zone'): 'zone',
                      copy.text('launcher.offset'): 'offset',
                    },
                    enabled: launcher.editable,
                    control: FSelectControl.lifted(
                      value: settings.mode,
                      onChange: (value) {
                        if (value != null) {
                          launcher.update(settings.copyWith(mode: value));
                        }
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: zoneWidth,
                  child: settings.mode == 'zone'
                      ? FSelect<String>.search(
                          key: const ValueKey('launcher-timezone'),
                          label: Text(copy.text('launcher.zone')),
                          description: Text(
                            copy.text('launcher.zoneDescription'),
                          ),
                          items: {
                            for (final zone in launcher.zones)
                              (copy.isEnglish
                                      ? zone.id
                                      : '${zone.label} · ${zone.id}'):
                                  zone.id,
                          },
                          enabled:
                              launcher.editable && launcher.zones.isNotEmpty,
                          control: FSelectControl.lifted(
                            value:
                                launcher.zones.any(
                                  (zone) => zone.id == settings.zoneId,
                                )
                                ? settings.zoneId
                                : null,
                            onChange: (value) {
                              if (value != null) {
                                launcher.update(
                                  settings.copyWith(zoneId: value),
                                );
                              }
                            },
                          ),
                        )
                      : FSelect<int>(
                          key: const ValueKey('launcher-offset'),
                          label: Text(copy.text('launcher.offset')),
                          description: Text(
                            copy.text('launcher.offsetDescription'),
                          ),
                          enabled: launcher.editable,
                          items: {
                            for (var i = -12; i <= 14; i++)
                              offsetLabel(i * 60): i,
                          },
                          control: FSelectControl.lifted(
                            value: settings.offset,
                            onChange: (value) {
                              if (value != null) {
                                launcher.update(
                                  settings.copyWith(offset: value),
                                );
                              }
                            },
                          ),
                        ),
                ),
              ],
            );
          },
        ),
        if (launcher.editable && launcher.validationError != null) ...[
          const SizedBox(height: 12),
          FAlert(
            variant: FAlertVariant.destructive,
            title: Text(_launcherStatus(copy, launcher.validationError!)),
          ),
        ],
      ],
    );
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
              child: _buttonText(copy.text('launcher.chooseClient')),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          launcher.effectivePath.isEmpty
              ? copy.text('launcher.noClient')
              : copy.text(
                  'launcher.currentPath',
                  args: {'path': launcher.effectivePath},
                ),
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
          label: Text(copy.text('launcher.skinCompatible')),
          description: Text(copy.text('launcher.skinDescription')),
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
                child: _buttonText(copy.text('launcher.openSkin')),
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
                child: _buttonText(copy.text('launcher.reapplySkin')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          copy.text('launcher.reapplyDescription'),
          style: context.theme.typography.body.sm.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
    final clientCard = _section(
      context,
      copy.text('launcher.client'),
      copy.text('launcher.clientDescription'),
      [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 720) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [clientPath, const FDivider(), skinControls],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: clientPath),
                const SizedBox(width: 24),
                Expanded(flex: 5, child: skinControls),
              ],
            );
          },
        ),
      ],
    );

    return FScaffold(
      childPad: false,
      footer: Container(
        decoration: BoxDecoration(
          color: DashboardPalette.of(context).panel,
          border: Border(top: BorderSide(color: context.theme.colors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                _launcherStatus(copy, launcher.message),
                style: context.theme.typography.body.sm,
              ),
            ),
            const SizedBox(height: 12),
            if (launcher.repairPackage != null) ...[
              Text(
                copy.text(
                  'launcher.repairDescription',
                  args: {'package': launcher.repairPackage},
                ),
                style: context.theme.typography.body.sm,
              ),
              if (launcher.repairLogPath != null)
                Text(
                  copy.text(
                    'launcher.launchLog',
                    args: {'path': launcher.repairLogPath},
                  ),
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
                      child: _buttonText(
                        launcher.busyCommand == 'repair_launch'
                            ? copy.text('launcher.repairing')
                            : copy.text('launcher.repair'),
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
                    child: _buttonText(
                      launcher.busyCommand == 'launch'
                          ? copy.text('launcher.launching')
                          : copy.text('launcher.launch'),
                    ),
                  ),
                ),
                if (launcher.platform == 'windows')
                  _motionButton(
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      variant: FButtonVariant.outline,
                      onPress: launcher.canLaunchAntigravity
                          ? () => launcher.action('launch_antigravity')
                          : null,
                      child: _buttonText(
                        copy.text('launcher.launchAntigravity'),
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
                    child: _buttonText(copy.text('launcher.save')),
                  ),
                ),
                _motionButton(
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.ghost,
                    onPress: launcher.editable && !launcher.preview
                        ? () => launcher.action('create_shortcut')
                        : null,
                    child: _buttonText(copy.text('launcher.shortcut')),
                  ),
                ),
                if (launcher.dirty)
                  FBadge(child: Text(copy.text('launcher.dirty'))),
                if (launcher.preview)
                  FBadge(child: Text(copy.text('launcher.preview'))),
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
                    title: Text(_launcherStatus(copy, launcher.message)),
                    subtitle: Text(launcher.error!),
                  ),
                  const SizedBox(height: 12),
                ],
                if (launcher.bootstrapFailed) ...[
                  _motionButton(
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: launcher.initialize,
                      child: _buttonText(copy.text('launcher.reload')),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final clock = ClockPanel(
                      settings: settings,
                      preview: launcher.preview,
                      compact: true,
                    );
                    if (constraints.maxWidth < 820) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          clock,
                          const SizedBox(height: 12),
                          settingCard,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: clock),
                        const SizedBox(width: 12),
                        Expanded(child: settingCard),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                clientCard,
                const SizedBox(height: 12),
                _section(
                  context,
                  copy.text('launcher.network'),
                  network.cached
                      ? copy.text('launcher.networkCached')
                      : copy.text('launcher.networkDescription'),
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
                          child: _buttonText(
                            network.busy
                                ? copy.text('launcher.querying')
                                : copy.text('launcher.refreshNetwork'),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final domestic = _NetworkRegion(
                          desktop: desktop,
                          title: copy.text('launcher.domestic'),
                          info: network.domestic,
                          error: network.errors['domestic'],
                          busy: network.busy,
                          launcher: launcher,
                        );
                        final international = _NetworkRegion(
                          desktop: desktop,
                          title: copy.text('launcher.international'),
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
                      Text(_launcherStatus(copy, network.errors['cache']!)),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  copy.text('launcher.exitFirst'),
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
    label: Text(AppCopy.of(context).text('launcher.path')),
    hint: AppCopy.of(context).text('launcher.pathHint'),
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
    final copy = AppCopy.of(context);
    ClockReading? target;
    DateTime? targetDate;
    try {
      target = targetClock(widget.settings, _now);
      targetDate = widget.settings.mode == 'offset'
          ? _now.toUtc().add(Duration(hours: widget.settings.offset))
          : tz.TZDateTime.from(_now, tz.getLocation(widget.settings.zoneId));
    } catch (_) {
      /* Unsupported zone remains visibly invalid. */
    }
    final local = widget.preview
        ? targetClock(const LauncherSettings(), _now)
        : ClockReading.fromDate(_now.toLocal());
    final localDate = widget.preview
        ? tz.TZDateTime.from(_now, tz.getLocation('Asia/Shanghai'))
        : _now.toLocal();
    final palette = DashboardPalette.of(context);
    final muted = context.theme.typography.body.sm.copyWith(
      color: palette.muted,
    );
    return FCard(
      key: const ValueKey('time-preview-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                Expanded(
                  child: Text(
                    copy.text('launcher.clock'),
                    style: context.theme.typography.display.lg,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              widget.settings.mode == 'zone'
                  ? widget.settings.zoneId
                  : copy.text('launcher.fixedOffset'),
              style: muted,
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                target?.time ?? '--:--:--',
                style: context.theme.typography.display.xl.copyWith(
                  fontSize: widget.compact ? 40 : 46,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.8,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  target == null
                      ? copy.text('launcher.validZone')
                      : copy.isEnglish
                      ? _clockDate(copy, targetDate!)
                      : target.date,
                  style: muted,
                ),
                FBadge(
                  child: Text(
                    target?.offset ?? copy.text('launcher.invalidZone'),
                  ),
                ),
              ],
            ),
            const FDivider(),
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
                      copy.text(
                        'launcher.localClock',
                        args: {
                          'zone': widget.preview
                              ? 'Asia/Shanghai'
                              : _now.toLocal().timeZoneName,
                        },
                      ),
                      style: muted,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      copy.isEnglish ? _clockDate(copy, localDate) : local.date,
                      style: muted,
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      local.time,
                      style: context.theme.typography.display.lg.copyWith(
                        fontSize: 20,
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
  String copyLabelKey = 'launcher.copyIp';
  Timer? _timer;
  Future<void> _copy() async {
    final ip = widget.info!.ip;
    try {
      await widget.desktop.copyVerified(ip);
      if (mounted) setState(() => copyLabelKey = 'launcher.copied');
    } catch (e) {
      if (mounted) {
        setState(() => copyLabelKey = 'launcher.copyFailed');
        widget.launcher.report('无法复制 IP。', detail: e.toString());
      }
    }
    _timer?.cancel();
    if (mounted) {
      _timer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => copyLabelKey = 'launcher.copyIp');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
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
            widget.busy
                ? copy.text('launcher.queryLocation')
                : widget.error ?? copy.text('launcher.noNetwork'),
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
                  child: _buttonText(copy.text(copyLabelKey)),
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
                  child: _buttonText(
                    supported
                        ? copy.text('launcher.applyZone')
                        : copy.text('launcher.unsupportedZone'),
                  ),
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

Widget _buttonText(String text) => Flexible(child: Text(text));

Widget _motionButton(FButton button) =>
    DashboardMotionFeedback(enabled: button.onPress != null, child: button);

String _clockDate(AppCopy copy, DateTime date) {
  // The target date has already been converted to the selected zone. A local
  // conversion here would incorrectly shift its calendar across midnight.
  final formatted = copy.dateTime(date, local: false);
  return '${formatted.substring(0, formatted.lastIndexOf(' '))} · ${copy.weekday(date)}';
}

/// Translate only recognized application summaries at this presentation edge.
/// Native error bodies, unknown messages and interpolated paths remain intact.
String _launcherStatus(AppCopy copy, String value) {
  if (!copy.isEnglish) return value;
  for (final entry in launcherMessages.entries) {
    if (entry.key.startsWith('launcher.status.') && entry.value.zh == value) {
      return copy.text(entry.key);
    }
  }
  const savedPrefix = '设置已保存到 ';
  if (value.startsWith(savedPrefix)) {
    return copy.text(
      'launcher.status.savedPath',
      args: {'path': value.substring(savedPrefix.length)},
    );
  }
  const zonePrefix = '已选择 ', zoneSuffix = '，保存并启动后生效。';
  if (value.startsWith(zonePrefix) && value.endsWith(zoneSuffix)) {
    return copy.text(
      'launcher.status.zoneApplied',
      args: {
        'zone': value.substring(
          zonePrefix.length,
          value.length - zoneSuffix.length,
        ),
      },
    );
  }
  const warning = '\n进程保持运行；日志记录不完整：';
  final warningIndex = value.indexOf(warning);
  if (warningIndex > 0) {
    final summary = value.substring(0, warningIndex);
    if (summary == launcherMessages['launcher.status.processStarted']!.zh ||
        summary == launcherMessages['launcher.status.processSkinStarted']!.zh) {
      return copy.text(
        'launcher.status.logWarning',
        args: {
          'summary': _launcherStatus(copy, summary),
          'details': value.substring(warningIndex + warning.length),
        },
      );
    }
  }
  return value;
}
