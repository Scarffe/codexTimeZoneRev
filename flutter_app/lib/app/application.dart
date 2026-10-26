import 'dart:async';

import '../l10n/app_language.dart';
import '../l10n/app_copy.dart';

import '../services/session_rhythm_store.dart';
import '../services/global_workbench_service.dart';
import '../services/global_workbench_store.dart';
import '../state/global_workbench_controller.dart';
import '../services/global_workbench.dart';
import '../state/session_rhythm_controller.dart';
import 'session_rhythm_panel.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/backend.dart';
import '../services/account_usage.dart';
import '../services/account_sources.dart';
import '../services/account_source_store.dart';
import '../services/quota_history_store.dart';
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
import '../state/quota_history_controller.dart';
import 'launcher_page.dart';
import 'accounts_workspace_page.dart';
import 'workspace_overview_page.dart';
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
import '../services/tasks.dart';
import '../services/task_store.dart';
import '../state/tasks_controller.dart';
import 'tasks_workspace_page.dart';

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
    this.historyStore,
    this.historyController,
    this.sessionMetricsController,
    this.attentionController,
    this.attentionStore,
    this.rhythmController,
    this.rhythmStore,
    this.tasksController,
    this.globalController,
  });
  final SessionRhythmController? rhythmController;
  final SessionRhythmStore? rhythmStore;
  final TasksController? tasksController;
  final GlobalWorkbenchController? globalController;
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
  final QuotaHistoryStore? historyStore;
  final QuotaHistoryController? historyController;
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
  late final QuotaHistoryStore historyStore =
      widget.historyStore ??
      widget.historyController?.store ??
      (widget.sourceController?.historySink is QuotaHistoryStore
          ? widget.sourceController!.historySink! as QuotaHistoryStore
          : (!widget.preview &&
                    !widget.offlineTrial &&
                    widget.backend == null &&
                    widget.usageService == null
                ? QuotaHistoryStore.portable()
                : QuotaHistoryStore.memory()));
  late final history =
      widget.historyController ?? QuotaHistoryController(historyStore);
  AccountSourcesController? _createSources() {
    final injected = widget.sourceController;
    if (injected != null) {
      // An application's offline policy also covers owners constructed elsewhere.
      if (widget.offlineTrial && !injected.service.synthetic) return null;
      // One application store is shared by capture and the history reader.
      // Explicit injection wins; existing non-store fixture sinks stay intact.
      if (widget.historyStore != null ||
          injected.historySink == null ||
          injected.historySink is QuotaHistoryStore) {
        injected.historySink = historyStore;
      }
      return injected;
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
      historySink: historyStore,
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
  late final rhythm =
      widget.rhythmController != null &&
          _allowedSessionBackend(widget.rhythmController!.backend)
      ? widget.rhythmController!
      : SessionRhythmController(
          backend: backend,
          store:
              widget.rhythmStore ??
              (!widget.preview && !widget.offlineTrial && widget.backend == null
                  ? SessionRhythmStore.portable()
                  : SessionRhythmStore.memory()),
        );
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
  late final global = _createGlobal();
  GlobalWorkbenchController _createGlobal() {
    final injected = widget.globalController;
    if (injected != null &&
        (!widget.offlineTrial ||
            injected.service is SyntheticGlobalWorkbenchService)) {
      return injected;
    }
    final production =
        !widget.preview && !widget.offlineTrial && widget.backend == null;
    return GlobalWorkbenchController(
      service: production
          ? GlobalWorkbenchService(backend)
          : SyntheticGlobalWorkbenchService(),
      store: production
          ? GlobalWorkbenchStore.portable()
          : GlobalWorkbenchStore.memory(),
    );
  }

  // Existing injected launcher fixtures opt in explicitly to the new backend.
  late final benchmark = _createBenchmark();
  BenchmarkController _createBenchmark() {
    final result =
        widget.benchmarkController ??
        BenchmarkController(
          BenchmarkService(backend),
          store:
              widget.backend == null && !widget.preview && !widget.offlineTrial
              ? BenchmarkStore.portable()
              : null,
          enabled:
              !widget.preview &&
              (widget.backend == null || widget.offlineTrial),
        );
    if (widget.preview || widget.offlineTrial) result.restrictToOffline();
    return result;
  }

  late final tasks = _createTasks();
  TasksController _createTasks() {
    final result =
        widget.tasksController ??
        TasksController(
          TaskService(
            backend,
            officialEnabled: !widget.preview && !widget.offlineTrial,
          ),
          store:
              widget.backend == null && !widget.preview && !widget.offlineTrial
              ? TaskStore.portable()
              : TaskStore.memory(),
        );
    if (widget.preview || widget.offlineTrial) result.restrictToPreview();
    return result;
  }

  late final appearance = ValueNotifier(widget.initialAppearance);
  late final themeStyle = ValueNotifier(widget.initialThemeStyle);
  final language = ValueNotifier(AppLanguage.zh);
  int _languageRevision = 0;
  int _appearanceRevision = 0, _styleRevision = 0;
  late bool acrylicEnabled = widget.acrylicEnabled;
  bool? materialDark;
  final windowChrome = WindowChrome();
  (DashboardThemeStyle, bool, AppLanguage)? chromeAppearance;
  DesktopMonitor? monitor;
  WorkspaceDestination selected = WorkspaceDestination.launcher;
  SessionAttentionNotice? openedNotice;
  RhythmAnalysisContext? openedHistory;
  int currentViewRevision = 0;
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
    final resolved = (themeStyle.value, dark, language.value);
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
        uiLanguage: resolved.$3.code,
      );
    });
  }

  final _navigator = GlobalKey<NavigatorState>();
  final _sessionPanel = GlobalKey();
  final _noticeContext = GlobalKey();
  int _analysisRevealRevision = 0;
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
    _analysisRevealRevision++;
    if (mounted) setState(() => selected = value);
  }

  void _revealAnalysis(GlobalKey target) {
    final revision = ++_analysisRevealRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          selected != WorkspaceDestination.analysis ||
          revision != _analysisRevealRevision) {
        return;
      }
      final targetContext = target.currentContext;
      if (targetContext != null && targetContext.mounted) {
        Scrollable.ensureVisible(targetContext, alignment: 0);
      }
    });
  }

  void _showAccountDetails() => _select(WorkspaceDestination.accounts);
  void _showAttentionDetails() => _select(WorkspaceDestination.sessions);
  void _showSessionDetails() {
    if (mounted) {
      setState(() {
        openedNotice = null;
        openedHistory = null;
        currentViewRevision++;
        selected = WorkspaceDestination.analysis;
      });
      _revealAnalysis(_sessionPanel);
    }
  }

  void _openAttentionNotice(SessionAttentionNotice notice) {
    if (!mounted) return;
    metrics.select(notice.path, expectedId: notice.sessionId);
    setState(() {
      openedNotice = notice;
      openedHistory = null;
      currentViewRevision++;
      selected = WorkspaceDestination.analysis;
    });
    _revealAnalysis(_noticeContext);
  }

  void _openRhythmSource(RhythmAnalysisContext history) {
    if (!mounted) return;
    metrics.select(history.source.path, expectedId: history.source.sessionId);
    setState(() {
      openedNotice = null;
      openedHistory = history;
      currentViewRevision++;
      selected = WorkspaceDestination.analysis;
    });
    _revealAnalysis(_noticeContext);
  }

  void _openGlobalSession(GlobalSessionRow row) {
    if (!mounted || !row.canOpenDetail) return;
    metrics.select(row.path, expectedId: row.threadId);
    setState(() {
      openedNotice = null;
      openedHistory = null;
      currentViewRevision++;
      selected = WorkspaceDestination.analysis;
    });
    _revealAnalysis(_sessionPanel);
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
          language: () => language.value,
          onNotice: (text) {
            if (mounted) setState(() => recentNotice = text);
          },
          onSessionDetails: _showSessionDetails,
          onAttentionDetails: _showAttentionDetails,
          attention: attention,
          rhythm: rhythm,
          metrics: metrics,
          benchmark: benchmark,
          tasks: tasks,
          global: global,
        )..start();
      }
    });
    unawaited(attention.initialize(attentionStore));
    unawaited(rhythm.initialize());
    unawaited(global.initialize());
    network.initialize();
    benchmark.initialize();
    if (!widget.preview && !widget.offlineTrial) {
      _loadLanguage();
    }
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

  Future<void> _loadLanguage() async {
    final revision = _languageRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || revision != _languageRevision) return;
      setState(
        () => language.value = AppLanguage.parse(prefs.get('flutter-language')),
      );
    } catch (_) {
      // Keep the visible choice when the preference service is unavailable.
    }
  }

  Future<void> _setLanguage(AppLanguage value) async {
    _languageRevision++;
    setState(() => language.value = value);
    monitor?.refreshPresentation();
    if (!widget.preview && !widget.offlineTrial) {
      try {
        if (!await (await SharedPreferences.getInstance()).setString(
          'flutter-language',
          value.code,
        )) {
          throw StateError('Language preference was not saved');
        }
      } catch (error) {
        if (mounted) {
          launcher.report(
            AppCopy(value).text('app.languageSaveFailure'),
            detail: error.toString(),
          );
        }
      }
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
        if (mounted) {
          launcher.report(
            AppCopy(language.value).text('app.themeSaveFailure'),
            detail: e.toString(),
          );
        }
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
        if (mounted) {
          launcher.report(
            AppCopy(language.value).text('app.styleSaveFailure'),
            detail: e.toString(),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => WidgetsApp(
    navigatorKey: _navigator,
    title: AppCopy(language.value).text('app.name'),
    color: const Color(0xff18181b),
    debugShowCheckedModeBanner: false,
    locale: language.value.locale,
    supportedLocales: AppLanguage.values.map((language) => language.locale),
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
        language: language.value,
      );
      return AppCopyScope(
        language: language.value,
        child: DashboardStyleScope(
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
          language,
          benchmark,
          attention,
          rhythm,
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
                          ? AppCopy.of(context).text('app.offlineSynthetic')
                          : AppCopy.of(context).text('app.offlineTrial'),
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
                    language: language.value,
                    onLanguage: _setLanguage,
                    onSettings: !usage.preferencesReady
                        ? null
                        : () => showGeneralDialog<void>(
                            context: context,
                            barrierDismissible: true,
                            barrierLabel: AppCopy.of(context)
                                .text('app.closeSettings'),
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
                      global: global,
                      onOpenSession: _openGlobalSession,
                    ),
                    accounts: AccountsWorkspacePage(
                      key: const ValueKey('accounts-page'),
                      history: history,
                      usage: usage,
                      launcher: launcher,
                    ),
                    sessions: TasksWorkspacePage(
                      key: const ValueKey('sessions-page'),
                      attention: attention,
                      tasks: tasks,
                      sources: sources,
                      onOpenNotice: _openAttentionNotice,
                    ),
                    analysis: MonitoringPage(
                      key: const ValueKey('analysis-page'),
                      launcher: launcher,
                      usage: usage,
                      metrics: metrics,
                      rhythm: rhythm,
                      onOpenRhythm: _openRhythmSource,
                      historyContext: openedHistory,
                      currentViewRevision: currentViewRevision,
                      onDismissHistory: () =>
                          setState(() => openedHistory = null),
                      sessionPanelKey: _sessionPanel,
                      noticeContextKey: _noticeContext,
                      notice: openedNotice,
                      onDismissNotice: () =>
                          setState(() => openedNotice = null),
                    ),
                    benchmark: benchmark.enabled
                        ? IndependentBenchmarkPanel(
                            key: const ValueKey('benchmark-page'),
                            controller: benchmark,
                          )
                        : SingleChildScrollView(
                            key: const PageStorageKey('benchmark-scroll'),
                            child: Text(
                              AppCopy.of(context).text('app.benchmarkPreview'),
                            ),
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
    history.dispose();
    sources?.dispose();
    metrics.dispose();
    unawaited(benchmark.shutdown());
    benchmark.dispose();
    unawaited(tasks.shutdown());
    tasks.dispose();
    appearance.dispose();
    language.dispose();
    themeStyle.dispose();
    attention.dispose();
    unawaited(rhythm.shutdown());
    rhythm.dispose();
    global.dispose();
    super.dispose();
  }
}
