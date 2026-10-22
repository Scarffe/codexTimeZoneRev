import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Keeps local observations mounted when the separate API entry is selected.
class SessionMeasurementWorkspace extends StatefulWidget {
  const SessionMeasurementWorkspace({
    super.key,
    required this.currentSession,
    this.independentApiSelected,
  });
  final Widget currentSession;
  final ValueNotifier<bool>? independentApiSelected;
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
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FButton(
                key: const ValueKey('measurement-current-session'),
                mainAxisSize: MainAxisSize.min,
                variant: api ? FButtonVariant.outline : FButtonVariant.primary,
                onPress: () =>
                    (widget.independentApiSelected ?? _localSelection).value =
                        false,
                child: const Text('当前会话'),
              ),
              FButton(
                key: const ValueKey('measurement-independent-api'),
                mainAxisSize: MainAxisSize.min,
                variant: api ? FButtonVariant.primary : FButtonVariant.outline,
                onPress: () =>
                    (widget.independentApiSelected ?? _localSelection).value =
                        true,
                child: const Text('独立 API 测速'),
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: api ? 1 : 0,
            children: [
              TickerMode(enabled: !api, child: widget.currentSession),
              TickerMode(
                enabled: api,
                child: SingleChildScrollView(
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
                          const Text('待 M2/M3 实现流式内核与可试用界面。当前尚不能发起 API 测速。'),
                          const Text('这里将使用单独的测试请求与结果，不使用当前会话日志作为 API 结果。'),
                        ],
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
