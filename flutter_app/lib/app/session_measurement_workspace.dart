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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MergeSemantics(
                    child: Semantics(
                      selected: !api,
                      child: _motionButton(
                        FButton(
                          key: const ValueKey('measurement-current-session'),
                          semanticsLabel: '当前会话',
                          mainAxisSize: MainAxisSize.min,
                          selected: !api,
                          variant: FButtonVariant.ghost,
                          onPress: () =>
                              (widget.independentApiSelected ?? _localSelection)
                                      .value =
                                  false,
                          child: const Text('当前会话'),
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
                          semanticsLabel: '独立 API',
                          mainAxisSize: MainAxisSize.min,
                          selected: api,
                          variant: FButtonVariant.ghost,
                          onPress: () =>
                              (widget.independentApiSelected ?? _localSelection)
                                      .value =
                                  true,
                          child: const Text('独立 API'),
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
                                  '独立 API 测速',
                                  style: context.theme.typography.display.lg,
                                ),
                                const SizedBox(height: 8),
                                const Text('独立来源 · 客户端观测'),
                                const Text('待实现'),
                                const Text('M2 离线内核已验收；真实接口与测速界面待实现'),
                                const Text(
                                  '这里将使用单独的测试请求与结果，不使用当前会话日志作为 API 结果。',
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
