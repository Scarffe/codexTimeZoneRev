import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import '../state/quota_history_controller.dart';
import '../state/runtime_account_controller.dart';
import 'account_sources_panel.dart';
import 'account_usage_panel.dart';
import 'quota_history_panel.dart';
import 'runtime_account_panel.dart';

class AccountsWorkspacePage extends StatefulWidget {
  const AccountsWorkspacePage({
    super.key,
    required this.usage,
    required this.launcher,
    this.history,
    this.runtime,
    this.revealCurrentRevision = 0,
  });
  final AccountUsageController usage;
  final LauncherController launcher;
  final QuotaHistoryController? history;
  final RuntimeAccountController? runtime;
  final int revealCurrentRevision;
  @override
  State<AccountsWorkspacePage> createState() => _AccountsWorkspacePageState();
}

class _AccountsWorkspacePageState extends State<AccountsWorkspacePage> {
  bool _history = false;
  final _quotaAnchor = GlobalKey();

  @override
  void didUpdateWidget(covariant AccountsWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealCurrentRevision == widget.revealCurrentRevision) return;
    _history = false;
    final revision = widget.revealCurrentRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != widget.revealCurrentRevision ||
          !TickerMode.valuesOf(context).enabled) {
        return;
      }
      final target = _quotaAnchor.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target, alignment: 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey('accounts-scroll'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(AppCopy.of(context).text('accounts.intro')),
        const SizedBox(height: 12),
        if (widget.usage.sources != null)
          AccountSourcesPanel(owner: widget.usage.sources!),
        if (widget.history != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FButton(
                key: const ValueKey('accounts-current'),
                mainAxisSize: MainAxisSize.min,
                variant: _history
                    ? FButtonVariant.outline
                    : FButtonVariant.primary,
                onPress: () => setState(() => _history = false),
                child: Text(AppCopy.of(context).text('accounts.current')),
              ),
              FButton(
                key: const ValueKey('accounts-history'),
                mainAxisSize: MainAxisSize.min,
                variant: _history
                    ? FButtonVariant.primary
                    : FButtonVariant.outline,
                onPress: () => setState(() => _history = true),
                child: Text(AppCopy.of(context).text('accounts.history')),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (_history && widget.history != null)
          QuotaHistoryPanel(
            controller: widget.history!,
            owner: widget.usage.sources,
          )
        else if (widget.usage.sources == null ||
            widget.usage.sources!.selected != null)
          AccountUsagePanel(
            key: _quotaAnchor,
            controller: widget.usage,
            launcher: widget.launcher,
          ),
        if (widget.runtime != null) ...[
          const SizedBox(height: 16),
          RuntimeAccountPanel(
            controller: widget.runtime!,
            sources: widget.usage.sources,
          ),
        ],
        const SizedBox(height: 16),
      ],
    ),
  );
}
