import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/backend.dart';
import '../services/account_usage.dart';
import '../services/desktop_monitor.dart';
import '../services/monitor_preferences.dart';
import '../services/session_selection.dart';
import '../services/desktop_services.dart';
import '../services/network_info.dart';
import '../services/window_material.dart';
import '../state/launcher_controller.dart';
import '../state/account_usage_controller.dart';
import 'launcher_page.dart';
import 'monitoring_page.dart';
import 'monitor_settings_dialog.dart';
import 'workspace_shell.dart';
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
  bool monitorSelected = false;
  String recentNotice = '';

  void _sourceChanged() {
    usage.sourceChanged(launcher.effectivePath);
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
  final _sessionPanel = GlobalKey();
  final _accountPanel = GlobalKey();
  final _independentApiSelected = ValueNotifier(false);
  void _showMonitor() {
    if (mounted) setState(() => monitorSelected = true);
  }

  void _showAccountDetails() {
    _independentApiSelected.value = false;
    _showMonitor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _accountPanel.currentContext;
      if (mounted && context != null) {
        Scrollable.ensureVisible(context, alignment: .1);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _showSessionDetails() {
    _independentApiSelected.value = false;
    _showMonitor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _sessionPanel.currentContext;
      if (mounted && context != null) {
        Scrollable.ensureVisible(context, alignment: .1);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    launcher.addListener(_sourceChanged);
    launcher.initialize().then((_) async {
      if (!widget.preview && widget.backend == null) {
        await usage.loadPreferences(MonitorPreferencesStore.portable());
      }
      if (mounted && !widget.preview && widget.backend == null) {
        await metrics.initialize(
          SessionSelectionStore.portable(),
          initialPath: widget.selectedSessionPath,
        );
      }
      // Explicit background mode also supports injected backends. Portable
      // preferences and session restoration above remain production-only.
      if (mounted &&
          !widget.preview &&
          (widget.backend == null || widget.monitorEnabled)) {
        monitor = DesktopMonitor(
          usage,
          () => launcher.effectivePath,
          interval: widget.monitorInterval,
          onMonitor: _showAccountDetails,
          backgroundStart: widget.monitorEnabled,
          workspace: () => monitorSelected ? 'monitor' : 'launcher',
          onNotice: (text) {
            if (mounted) setState(() => recentNotice = text);
          },
          onSessionDetails: _showSessionDetails,
          metrics: metrics,
        )..start();
      }
    });
    network.initialize();
    if (!widget.preview && widget.backend == null) _loadAppearance();
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
    if (!widget.preview && widget.backend == null) {
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
        listenable: Listenable.merge([
          launcher,
          network,
          usage,
          metrics,
          appearance,
        ]),
        builder: (context, _) => TickerMode(
          enabled: usage.mainWindowVisible,
          child: Offstage(
            offstage: !usage.mainWindowVisible,
            child: WorkspaceShell(
              monitorSelected: monitorSelected,
              onSelect: (value) => setState(() => monitorSelected = value),
              appearance: appearance.value,
              onAppearance: _setAppearance,
              onSettings: !usage.preferencesReady
                  ? null
                  : () => showGeneralDialog<void>(
                      context: context,
                      barrierDismissible: true,
                      barrierLabel: '关闭监控设置',
                      pageBuilder: (context, _, _) =>
                          MonitorSettingsDialog(controller: usage),
                    ),
              launcher: LauncherPage(
                key: const ValueKey('launcher-page'),
                desktop: widget.desktop,
                launcher: launcher,
                network: network,
              ),
              monitor: MonitoringPage(
                key: const ValueKey('monitor-page'),
                launcher: launcher,
                usage: usage,
                metrics: metrics,
                sessionPanelKey: _sessionPanel,
                accountPanelKey: _accountPanel,
                recentNotice: recentNotice,
                independentApiSelected: _independentApiSelected,
              ),
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
    _independentApiSelected.dispose();
    super.dispose();
  }
}
