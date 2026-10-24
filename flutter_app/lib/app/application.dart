import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/backend.dart';
import '../services/account_usage.dart';
import '../services/account_sources.dart';
import '../services/account_source_store.dart';
import '../services/desktop_monitor.dart';
import '../services/monitor_preferences.dart';
import '../services/session_selection.dart';
import '../services/desktop_services.dart';
import '../services/network_info.dart';
import '../services/window_material.dart';
import '../services/window_chrome.dart';
import '../state/launcher_controller.dart';
import '../state/account_usage_controller.dart';
import '../state/account_sources_controller.dart';
import 'launcher_page.dart';
import 'accounts_workspace_page.dart';
import 'workspace_overview_page.dart';
import 'session_attention_page.dart';
import 'independent_benchmark_panel.dart';
import '../services/session_attention.dart';
import '../services/session_attention_store.dart';
import '../services/memory_attention_store.dart';
import '../state/session_attention_controller.dart';
import 'monitoring_page.dart';
import 'monitor_settings_dialog.dart';
import 'workspace_shell.dart';
import 'dashboard_motion.dart';
import 'dashboard_style.dart';
import 'theme.dart';
import '../state/session_metrics_controller.dart';
import '../state/benchmark_controller.dart';
import '../services/benchmark.dart';
import '../services/benchmark_store.dart';

/// Reads only the app appearance keys; malformed family never hides valid mode.
({String? appearance, DashboardThemeStyle style})
readLauncherAppearancePreferences(SharedPreferences prefs) {
  final mode = prefs.get('flutter-appearance');
  return (
    appearance: ['system', 'light', 'dark'].contains(mode)
        ? mode as String
        : null,
    style: DashboardThemeStyle.parse(prefs.get('flutter-theme-style')),
  );
}

Future<void> saveLauncherThemeStyle(
  SharedPreferences prefs,
  DashboardThemeStyle style,
) async {
  if (!await prefs.setString('flutter-theme-style', style.id)) {
    throw StateError('Theme style preference was not saved');
  }
}

class LauncherApplication extends StatefulWidget {
  const LauncherApplication({
    super.key,
    this.preview = false,
    this.backend,
    this.initialAppearance = 'system',
    this.initialThemeStyle = DashboardThemeStyle.soft,
    this.desktop = const SystemDesktopServices(),
    this.networkFactory,
    this.acrylicEnabled = false,
    this.usageService,
    this.monitorEnabled = false,
    this.selectedSessionPath,
    this.monitorInterval = const Duration(minutes: 2),
    this.offlineTrial = false,
    this.benchmarkController,
    this.sourceController,
    this.sourcesService,
    this.sourcesStore,
    this.sessionMetricsController,
    this.attentionController,
    this.attentionStore,
  });
  final bool preview;
  final LauncherBackend? backend;
  final String initialAppearance;
  final DashboardThemeStyle initialThemeStyle;
  final DesktopServices desktop;
  final NetworkController Function()? networkFactory;
  final bool acrylicEnabled;
  final AccountUsageService? usageService;
  final bool monitorEnabled;
  final String? selectedSessionPath;
  final Duration monitorInterval;
  final bool offlineTrial;
  final BenchmarkController? benchmarkController;
  final AccountSourcesController? sourceController;
  final AccountSourcesService? sourcesService;
  final AccountSourceStore? sourcesStore;
  final SessionMetricsController? sessionMetricsController;
  final SessionAttentionController? attentionController;
  final SessionAttentionStore? attentionStore;
  @override
  State<LauncherApplication> createState() => _LauncherApplicationState();
}

class _LauncherApplicationState extends State<LauncherApplication> {
  late final LauncherBackend backend = widget.offlineTrial
      ? OfflineTrialBackend(widget.backend ?? const NativeBackend())
      : widget.backend ??
            (widget.preview ? const PreviewBackend() : const NativeBackend());
  late final launcher = LauncherController(
    backend,
    preview: widget.preview,
    offlineTrial: widget.offlineTrial,
  );
  late final network = widget.offlineTrial
      ? NetworkController(offlineTrial: true)
      : widget.networkFactory?.call() ??
            NetworkController(preview: widget.preview);
  late final AccountSourcesController? sources = _createSources();
  AccountSourcesController? _createSources() {
    final injected = widget.sourceController;
    if (injected != null) {
      // An application's offline policy also covers owners constructed elsewhere.
      return widget.offlineTrial && !injected.service.synthetic
          ? null
          : injected;
    }
    final production =
        !widget.preview &&
        widget.backend == null &&
        widget.usageService == null;
    if (widget.sourcesService == null && !production) return null;
    return AccountSourcesController(
      widget.sourcesService ??
          NativeAccountSourcesService(
            backend,
            offlineTrial: widget.offlineTrial,
          ),
      widget.sourcesStore ??
          (production && !widget.offlineTrial
              ? AccountSourceStore.portable()
              : AccountSourceStore.memory()),
      offlineTrial: widget.offlineTrial,
    );
  }

  late final usage = AccountUsageController(
    widget.usageService ??
        NativeAccountUsageService(
          launcher.backend,
          offlineTrial: widget.offlineTrial,
        ),
    offlineTrial: widget.offlineTrial,
    sources: sources,
  );
  bool _allowedSessionBackend(LauncherBackend backend) =>
      !widget.offlineTrial ||
      backend is SyntheticSessionBackend ||
      backend is PreviewBackend;
  late final metrics =
      widget.sessionMetricsController != null &&
          _allowedSessionBackend(widget.sessionMetricsController!.backend)
      ? widget.sessionMetricsController!
      : SessionMetricsController(launcher.backend);
  late final attention =
      widget.attentionController != null &&
          _allowedSessionBackend(widget.attentionController!.backend)
      ? widget.attentionController!
      : SessionAttentionController(launcher.backend);
  late final attentionStore =
      widget.attentionStore ??
      (!widget.preview && !widget.offlineTrial && widget.backend == null
          ? SessionAttentionStore.portable()
          : MemoryAttentionStore());
  // Existing injected launcher fixtures opt in explicitly to the new backend.
  late final benchmark =
      widget.benchmarkController ??
      BenchmarkController(
        BenchmarkService(backend),
        store: widget.backend == null && !widget.preview && !widget.offlineTrial
            ? BenchmarkStore.portable()
            : null,
        enabled:
            !widget.preview && (widget.backend == null || widget.offlineTrial),
      );
  late final appearance = ValueNotifier(widget.initialAppearance);
  late final themeStyle = ValueNotifier(widget.initialThemeStyle);
  int _appearanceRevision = 0, _styleRevision = 0;
  late bool acrylicEnabled = widget.acrylicEnabled;
  bool? materialDark;
  final windowChrome = WindowChrome();
  (DashboardThemeStyle, bool)? chromeAppearance;
  DesktopMonitor? monitor;
  WorkspaceDestination selected = WorkspaceDestination.launcher;
  SessionAttentionNotice? openedNotice;
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

  void _syncChrome(bool dark) {
    final resolved = (themeStyle.value, dark);
    if (chromeAppearance == resolved) return;
    chromeAppearance = resolved;
    final palette = DashboardPalette.forBrightness(
      dark ? Brightness.dark : Brightness.light,
      style: themeStyle.value,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      windowChrome.apply(
        dark: dark,
        captionArgb: palette.background.toARGB32(),
        textArgb: palette.foreground.toARGB32(),
        borderArgb: palette.border.toARGB32(),
        menuSurfaceArgb: palette.panel.toARGB32(),
        menuSelectedArgb: palette.selected.toARGB32(),
        menuAccentArgb: palette.controlAccent.toARGB32(),
        menuDangerArgb: palette.danger.toARGB32(),
      );
    });
  }

  final _navigator = GlobalKey<NavigatorState>();
  final _sessionPanel = GlobalKey();
  Widget _benchmarkKeyboard(Widget child) => CallbackShortcuts(
    bindings: {
      if (selected == WorkspaceDestination.benchmark &&
          usage.mainWindowVisible) ...{
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (_navigator.currentState?.canPop() != true && benchmark.canStart) {
            benchmark.start();
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_navigator.currentState?.canPop() != true &&
              benchmark.canCancel) {
            benchmark.cancel();
          }
        },
      },
    },
    child: child,
  );
  void _select(WorkspaceDestination value) {
    if (mounted) setState(() => selected = value);
  }

  void _showAccountDetails() => _select(WorkspaceDestination.accounts);
  void _showAttentionDetails() => _select(WorkspaceDestination.sessions);
  void _showSessionDetails() {
    if (mounted) {
      setState(() {
        openedNotice = null;
        selected = WorkspaceDestination.analysis;
      });
    }
  }

  void _openAttentionNotice(SessionAttentionNotice notice) {
    metrics.select(notice.path, expectedId: notice.sessionId);
    setState(() {
      openedNotice = notice;
      selected = WorkspaceDestination.analysis;
    });
  }

  @override
  void initState() {
    super.initState();
    launcher.initialize().then((_) async {
      if (!widget.preview && !widget.offlineTrial && widget.backend == null) {
        await usage.loadPreferences(MonitorPreferencesStore.portable());
      }
      if (!mounted) return;
      await sources?.initialize(() => launcher.effectivePath);
      if (!mounted) return;
      launcher.addListener(_sourceChanged);
      _sourceChanged();
      if (mounted &&
          !widget.preview &&
          !widget.offlineTrial &&
          widget.backend == null) {
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
          workspace: () => selected.name,
          onNotice: (text) {
            if (mounted) setState(() => recentNotice = text);
          },
          onSessionDetails: _showSessionDetails,
          onAttentionDetails: _showAttentionDetails,
          attention: attention,
          metrics: metrics,
          benchmark: benchmark,
        )..start();
      }
    });
    unawaited(attention.initialize(attentionStore));
    network.initialize();
    benchmark.initialize();
    if (!widget.preview && !widget.offlineTrial && widget.backend == null) {
      _loadAppearance();
    }
  }

  Future<void> _loadAppearance() async {
    final modeRevision = _appearanceRevision, styleRevision = _styleRevision;
    try {
      final saved = readLauncherAppearancePreferences(
        await SharedPreferences.getInstance(),
      );
      if (!mounted) return;
      setState(() {
        // A delayed disk result must not undo an action taken since startup.
        if (_appearanceRevision == modeRevision && saved.appearance != null) {
          appearance.value = saved.appearance!;
        }
        if (_styleRevision == styleRevision) themeStyle.value = saved.style;
      });
    } catch (_) {
      /* Current in-memory appearance is a safe fallback. */
    }
  }

  Future<void> _setAppearance(String value) async {
    _appearanceRevision++;
    setState(() => appearance.value = value);
    if (!widget.preview && !widget.offlineTrial && widget.backend == null) {
      try {
        if (!await (await SharedPreferences.getInstance()).setString(
          'flutter-appearance',
          value,
        )) {
          throw StateError('Appearance preference was not saved');
        }
      } catch (e) {
        if (mounted) launcher.report('主题已切换，但无法保存偏好。', detail: e.toString());
      }
    }
  }

  Future<void> _setThemeStyle(DashboardThemeStyle value) async {
    _styleRevision++;
    setState(() => themeStyle.value = value);
    if (!widget.preview && !widget.offlineTrial && widget.backend == null) {
      try {
        await saveLauncherThemeStyle(
          await SharedPreferences.getInstance(),
          value,
        );
      } catch (e) {
        if (mounted) launcher.report('风格已切换，但无法保存偏好。', detail: e.toString());
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
      _syncChrome(dark);
      final theme = launcherTheme(
        dark,
        acrylic: acrylicEnabled,
        style: themeStyle.value,
      );
      return DashboardStyleScope(
        style: themeStyle.value,
        child: FTheme(
          data: theme,
          child: ListenableBuilder(
            listenable: usage,
            child: FToaster(
              child: FTooltipGroup(
                child: DefaultTextStyle(
                  style: theme.typography.body.md.copyWith(
                    color: theme.colors.foreground,
                  ),
                  child: _benchmarkKeyboard(child!),
                ),
              ),
            ),
            builder: (context, child) => DashboardMotionScope(
              reducedMotion: usage.reducedMotion || !usage.mainWindowVisible,
              child: DashboardMotionBackdrop(child: child!),
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
          themeStyle,
          benchmark,
          attention,
        ]),
        builder: (context, _) => TickerMode(
          enabled: usage.mainWindowVisible,
          child: Offstage(
            offstage: !usage.mainWindowVisible,
            child: Column(
              children: [
                if (widget.offlineTrial)
                  Container(
                    width: double.infinity,
                    color: DashboardPalette.of(context).soft,
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      sources?.service.synthetic == true
                          ? '离线试用 · 仅合成来源可操作；真实账号查询与客户端启动已停用。'
                          : '离线试用 · 公网、账号查询与客户端启动已停用；主题仅本次生效。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: DashboardPalette.of(context).foreground,
                      ),
                    ),
                  ),
                Expanded(
                  child: WorkspaceShell(
                    selected: selected,
                    onSelect: _select,
                    unreadCount: attention.unreadCount,
                    appearance: appearance.value,
                    onAppearance: _setAppearance,
                    themeStyle: themeStyle.value,
                    onThemeStyle: _setThemeStyle,
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
                    overview: WorkspaceOverviewPage(
                      key: const ValueKey('overview-page'),
                      usage: usage,
                      metrics: metrics,
                      attention: attention,
                      onSelect: _select,
                      recentNotice: recentNotice,
                    ),
                    accounts: AccountsWorkspacePage(
                      key: const ValueKey('accounts-page'),
                      usage: usage,
                      launcher: launcher,
                    ),
                    sessions: SessionAttentionPage(
                      key: const ValueKey('sessions-page'),
                      controller: attention,
                      onOpenNotice: _openAttentionNotice,
                    ),
                    analysis: MonitoringPage(
                      key: const ValueKey('analysis-page'),
                      launcher: launcher,
                      usage: usage,
                      metrics: metrics,
                      sessionPanelKey: _sessionPanel,
                      notice: openedNotice,
                      onDismissNotice: () =>
                          setState(() => openedNotice = null),
                    ),
                    benchmark: benchmark.enabled
                        ? IndependentBenchmarkPanel(
                            key: const ValueKey('benchmark-page'),
                            controller: benchmark,
                          )
                        : const SingleChildScrollView(
                            key: PageStorageKey('benchmark-scroll'),
                            child: Text('独立 API 测速 · 当前预览未启用。'),
                          ),
                  ),
                ),
              ],
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
    sources?.dispose();
    metrics.dispose();
    benchmark.dispose();
    appearance.dispose();
    themeStyle.dispose();
    attention.dispose();
    super.dispose();
  }
}
