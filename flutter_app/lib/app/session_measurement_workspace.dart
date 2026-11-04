import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'dashboard_motion.dart';

import 'dashboard_style.dart';

/// Keeps local observations mounted when the separate API entry is selected.
class SessionMeasurementWorkspace extends StatefulWidget {
  const SessionMeasurementWorkspace({
    super.key,
    required this.currentSession,
    this.independentApiSelected,
    this.independentApi,
  });
  final Widget currentSession;
  final ValueNotifier<bool>? independentApiSelected;
  final Widget? independentApi;
  @override
  State<SessionMeasurementWorkspace> createState() =>
      _SessionMeasurementWorkspaceState();
}

class _SessionMeasurementWorkspaceState
    extends State<SessionMeasurementWorkspace> {
  final _localSelection = ValueNotifier(false);
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.independentApiSelected ?? _localSelection,
    builder: (context, api, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: DashboardPalette.of(context).soft,
                border: Border.all(color: DashboardPalette.of(context).border),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  MergeSemantics(
                    child: Semantics(
                      selected: !api,
                      child: _motionButton(
                        FButton(
                          key: const ValueKey('measurement-current-session'),
                          semanticsLabel: AppCopy.of(context)
                              .text('analysis.currentSession'),
                          mainAxisSize: MainAxisSize.min,
                          selected: !api,
                          variant: FButtonVariant.ghost,
                          onPress: () =>
                              (widget.independentApiSelected ?? _localSelection)
                                      .value =
                                  false,
                          child: Text(
                            AppCopy.of(context).text('analysis.currentSession'),
                          ),
                        ),
                      ),
                    ),
                  ),
                  MergeSemantics(
                    child: Semantics(
                      selected: api,
                      child: _motionButton(
                        FButton(
                          key: const ValueKey('measurement-independent-api'),
                          semanticsLabel: AppCopy.of(context)
                              .text('analysis.independentAPI'),
                          mainAxisSize: MainAxisSize.min,
                          selected: api,
                          variant: FButtonVariant.ghost,
                          onPress: () =>
                              (widget.independentApiSelected ?? _localSelection)
                                      .value =
                                  true,
                          child: Text(
                            AppCopy.of(context).text('analysis.independentAPI'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: api ? 1 : 0,
            children: [
              TickerMode(
                enabled: !api,
                child: ExcludeFocus(
                  excluding: api,
                  child: widget.currentSession,
                ),
              ),
              TickerMode(
                enabled: api,
                child: ExcludeFocus(
                  excluding: !api,
                  child:
                      widget.independentApi ??
                      SingleChildScrollView(
                        key: const PageStorageKey('independent-api-scroll'),
                        child: FCard(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  AppCopy.of(context)
                                      .text('analysis.independentAPIBenchmark'),
                                  style: context.theme.typography.display.lg,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  AppCopy.of(context).text(
                                    'analysis.independentSourceClientObservations',
                                  ),
                                ),
                                Text(
                                  AppCopy.of(context)
                                      .text('analysis.notYetImplemented'),
                                ),
                                Text(
                                  AppCopy.of(context).text(
                                    'analysis.m2OfflineEngineVerifiedLiveAPIAnd',
                                  ),
                                ),
                                Text(
                                  AppCopy.of(context).text(
                                    'analysis.thisViewUsesSeparateTestRequestsAnd',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _localSelection.dispose();
    super.dispose();
  }
}

Widget _motionButton(FButton button) =>
    DashboardMotionFeedback(enabled: button.onPress != null, child: button);
