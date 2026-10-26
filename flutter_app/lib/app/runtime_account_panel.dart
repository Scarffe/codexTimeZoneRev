import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../l10n/app_copy.dart';
import '../services/runtime_account.dart';
import '../state/account_sources_controller.dart';
import '../state/runtime_account_controller.dart';
import 'dashboard_style.dart';

class RuntimeAccountPanel extends StatelessWidget {
  const RuntimeAccountPanel({
    super.key,
    required this.controller,
    this.sources,
  });
  final RuntimeAccountController controller;
  final AccountSourcesController? sources;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, ?sources]),
    builder: (context, _) {
      final copy = AppCopy.of(context);
      final palette = DashboardPalette.of(context);
      final state = controller.status;
      final selected = sources?.selected;
      final errorKey = _errorKey(state.errorKind);
      final unresolvedIntent =
          controller.requestedSourceId != null && errorKey != null;
      final signedIn =
          selected != null &&
          selected.id != 'current' &&
          !const {
            'auth_required',
            'auth_failed',
            'identity_changed',
          }.contains(selected.errorKind) &&
          (selected.usage != null || selected.loginState == 'succeeded');
      final canUse =
          signedIn &&
          sources!.canOperate &&
          !selected.pendingRemoval &&
          !selected.loggingIn &&
          !selected.busy &&
          state.connected &&
          !controller.busy &&
          !state.preparing &&
          !state.pendingSourceRetained &&
          state.phase != 'unresolved' &&
          !unresolvedIntent;
      final phase = state.preparing
          ? 'preparing'
          : unresolvedIntent
          ? 'unresolved'
          : state.phase;
      final pending =
          state.preparing ||
          state.pendingSourceRetained ||
          const {'awaiting_confirmation', 'unresolved'}.contains(state.phase) ||
          unresolvedIntent;
      final activeAlias = state.sourceId == null
          ? null
          : _alias(context, state.sourceId!);
      final text = context.theme.typography.body;
      final statusColor = state.phase == 'unresolved' || errorKey != null
          ? palette.danger
          : state.phase == 'active'
          ? palette.tool
          : palette.muted;
      return Container(
        key: const ValueKey('runtime-account-panel'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.border),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            Widget action(
              String key,
              String label,
              VoidCallback? onPress, {
              FButtonVariant variant = FButtonVariant.outline,
            }) => ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: FButton(
                key: ValueKey(key),
                mainAxisSize: MainAxisSize.min,
                variant: variant,
                onPress: onPress,
                child: Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      copy.text('runtime.title'),
                      style: text.lg.copyWith(color: palette.foreground),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: palette.soft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        copy.text(
                          controller.busy
                              ? 'runtime.working'
                              : 'runtime.phase.$phase',
                        ),
                        style: text.sm.copyWith(color: statusColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  key: const ValueKey('runtime-current-account'),
                  activeAlias == null
                      ? copy.text(
                          state.activeSourceRetained
                              ? 'runtime.retainedUnknown'
                              : 'runtime.unbound',
                        )
                      : copy.text(
                          phase == 'active'
                              ? 'runtime.currentAlias'
                              : 'runtime.retainedAlias',
                          args: {'alias': activeAlias},
                        ),
                  style: text.md.copyWith(color: palette.foreground),
                ),
                if (pending && controller.requestedSourceId != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    copy.text(
                      'runtime.requestedAlias',
                      args: {
                        'alias': _alias(context, controller.requestedSourceId!),
                      },
                    ),
                    style: text.sm.copyWith(color: palette.muted),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!state.connected)
                      action(
                        'runtime-connect',
                        copy.text('runtime.connect'),
                        state.supported &&
                                !controller.busy &&
                                !controller.checking
                            ? controller.connect
                            : null,
                      ),
                    if (selected != null)
                      action(
                        'runtime-use-source',
                        copy.text(
                          'runtime.useSource',
                          args: {'alias': selected.alias},
                        ),
                        canUse ? () => controller.useSource(selected.id) : null,
                        variant: FButtonVariant.primary,
                      ),
                    if (pending ||
                        (controller.busy &&
                            controller.requestedSourceId != null))
                      action(
                        'runtime-cancel',
                        copy.text('runtime.cancel'),
                        controller.cancel,
                      ),
                    if (pending ||
                        (controller.requestedSourceId != null &&
                            errorKey != null))
                      action(
                        'runtime-reconcile',
                        copy.text('runtime.reconcile'),
                        state.connected && !controller.busy
                            ? controller.reconcile
                            : null,
                      ),
                    action(
                      'runtime-refresh',
                      copy.text('runtime.refresh'),
                      !controller.busy && !controller.checking
                          ? controller.refresh
                          : null,
                      variant: FButtonVariant.ghost,
                    ),
                  ],
                ),
                if (selected != null && !signedIn) ...[
                  const SizedBox(height: 8),
                  Text(
                    copy.text('runtime.loginFirst'),
                    style: text.sm.copyWith(color: palette.muted),
                  ),
                ],
                if (errorKey != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    copy.text(errorKey),
                    style: text.sm.copyWith(color: palette.danger),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  copy.text('runtime.inFlight'),
                  style: text.sm.copyWith(color: palette.muted),
                ),
                if (controller.service is SyntheticRuntimeAccountService) ...[
                  const SizedBox(height: 5),
                  Text(
                    copy.text('runtime.synthetic'),
                    style: text.sm.copyWith(color: palette.muted),
                  ),
                ],
              ],
            );
          },
        ),
      );
    },
  );

  String _alias(BuildContext context, String id) =>
      sources?.states.where((source) => source.id == id).firstOrNull?.alias ??
      AppCopy.of(context).text('runtime.otherSource');

  String? _errorKey(String? kind) => switch (kind) {
    null => null,
    'auth_required' => 'runtime.error.auth',
    'owner_busy' || 'source_busy' || 'busy' => 'runtime.error.busy',
    'invalid_target' ||
    'target_not_found' ||
    'target_exited' => 'runtime.error.target',
    'unsupported' => 'runtime.error.unsupported',
    'isolation_failed' ||
    'cli_changed' ||
    'identity_changed' ||
    'source_mismatch' => 'runtime.error.configuration',
    'delivery_unresolved' => 'runtime.error.pending',
    'cancelled' => 'runtime.error.cancelled',
    _ => 'runtime.error.retry',
  };
}
