import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/backend.dart';
import '../services/account_usage.dart';
import '../services/desktop_monitor.dart';
import '../services/monitor_preferences.dart';
import '../services/desktop_services.dart';
import '../services/network_info.dart';
import '../services/window_material.dart';
import '../state/launcher_controller.dart';
import '../state/account_usage_controller.dart';
import 'launcher_page.dart';
import 'pet_role_dialog.dart';
import 'theme.dart';
import '../state/session_metrics_controller.dart';

class LauncherApplication extends StatefulWidget {
  const LauncherApplication({
    super.key,
    this.preview = false,
    this.backend,
    this.initialAppearance = 'system',
    this.desktop = const SystemDesktopServices(),
    this.networkFactory,
    this.acrylicEnabled = false,
    this.usageService,
    this.monitorEnabled = false,
    this.selectedSessionPath,
    this.monitorInterval = const Duration(minutes: 2),
  });
  final bool preview;
  final LauncherBackend? backend;
  final String initialAppearance;
  final DesktopServices desktop;
  final NetworkController Function()? networkFactory;
  final bool acrylicEnabled;
  final AccountUsageService? usageService;
  final bool monitorEnabled;
  final String? selectedSessionPath;
  final Duration monitorInterval;
  @override
  State<LauncherApplication> createState() => _LauncherApplicationState();
}

class _LauncherApplicationState extends State<LauncherApplication> {
  late final launcher = LauncherController(
    widget.backend ??
        (widget.preview ? const PreviewBackend() : const NativeBackend()),
    preview: widget.preview,
  );
  late final network =
      widget.networkFactory?.call() ??
      NetworkController(preview: widget.preview);
  late final usage = AccountUsageController(
    widget.usageService ?? NativeAccountUsageService(launcher.backend),
  );
  late final metrics = SessionMetricsController(launcher.backend);
  late final appearance = ValueNotifier(widget.initialAppearance);
  late bool acrylicEnabled = widget.acrylicEnabled;
  bool? materialDark;
  DesktopMonitor? monitor;

  void _sourceChanged() {
    if (widget.monitorEnabled) usage.sourceChanged(launcher.effectivePath);
  }

  void _syncMaterial(bool dark) {
    if (!acrylicEnabled || materialDark == dark) return;
    materialDark = dark;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await WindowMaterial.apply(dark);
      } catch (_) {
        if (mounted) setState(() => acrylicEnabled = false);
      }
    });
  }

  final _navigator = GlobalKey<NavigatorState>();
  bool _rolesOpen = false;
  Future<void> _openRoles() async {
    final context = _navigator.currentState?.overlay?.context;
    if (context == null || _rolesOpen) return;
    _rolesOpen = true;
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭角色面板',
        pageBuilder: (_, _, _) => PetRoleDialog(controller: usage),
      );
    } finally {
      _rolesOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    launcher.addListener(_sourceChanged);
    launcher.initialize().then((_) async {
      if (!widget.preview && widget.backend == null) {
        await usage.loadPreferences(MonitorPreferencesStore.portable());
        await usage.roles.load();
      }
      if (mounted && !widget.preview && widget.selectedSessionPath != null) {
        metrics.select(widget.selectedSessionPath);
      }
      if (mounted && widget.monitorEnabled && !widget.preview) {
        monitor = DesktopMonitor(
          usage,
          () => launcher.effectivePath,
          interval: widget.monitorInterval,
          onRoles: _openRoles,
          metrics: metrics,
        )..start();
      }
    });
    network.initialize();
    if (!widget.preview) _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        'flutter-appearance',
      );
      if (mounted && ['system', 'light', 'dark'].contains(saved)) {
        setState(() => appearance.value = saved!);
      }
    } catch (_) {
      /* System appearance is a safe fallback. */
    }
  }

  Future<void> _setAppearance(String value) async {
    setState(() => appearance.value = value);
    if (!widget.preview) {
      try {
        await (await SharedPreferences.getInstance()).setString(
          'flutter-appearance',
          value,
        );
      } catch (e) {
        launcher.report('主题已切换，但无法保存偏好。', detail: e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) => WidgetsApp(
    navigatorKey: _navigator,
    title: 'Codex 时区启动器',
    color: const Color(0xff18181b),
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: FLocalizations.supportedLocales,
    localizationsDelegates: FLocalizations.localizationsDelegates,
    builder: (context, child) {
      final dark =
          appearance.value == 'dark' ||
          (appearance.value == 'system' &&
              MediaQuery.platformBrightnessOf(context) == Brightness.dark);
      _syncMaterial(dark);
      final theme = acrylicEnabled
          ? (dark ? darkAcrylicTheme : lightAcrylicTheme)
          : (dark ? darkLauncherTheme : lightLauncherTheme);
      return FTheme(
        data: theme,
        child: FToaster(
          child: FTooltipGroup(
            child: DefaultTextStyle(
              style: theme.typography.body.md.copyWith(
                color: theme.colors.foreground,
              ),
              child: child!,
            ),
          ),
        ),
      );
    },
    onGenerateRoute: (settings) => PageRouteBuilder<void>(
      settings: settings,
      pageBuilder: (context, animation, secondary) => ListenableBuilder(
        listenable: Listenable.merge([launcher, network, usage, appearance]),
        builder: (context, _) => TickerMode(
          enabled: !widget.monitorEnabled || usage.mainWindowVisible,
          child: Offstage(
            offstage: widget.monitorEnabled && !usage.mainWindowVisible,
            child: LauncherPage(
              desktop: widget.desktop,
              launcher: launcher,
              network: network,
              usage: usage,
              metrics: widget.preview ? null : metrics,
              appearance: appearance.value,
              onAppearance: _setAppearance,
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    monitor?.dispose();
    launcher.removeListener(_sourceChanged);
    launcher.dispose();
    network.dispose();
    usage.dispose();
    metrics.dispose();
    appearance.dispose();
    super.dispose();
  }
}
