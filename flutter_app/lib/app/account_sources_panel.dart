import '../l10n/app_copy.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/account_sources.dart';
import '../services/account_usage.dart';
import '../state/account_sources_controller.dart';
import 'monitor_charts.dart';
import 'account_usage_panel.dart' show quotaWindowLabel;
import 'monitor_information.dart';
import 'monitor_presentation.dart';

/// Source selection affects quota observations only. Identities stay in details.
class AccountSourcesPanel extends StatefulWidget {
  const AccountSourcesPanel({super.key, required this.owner});
  final AccountSourcesController owner;
  @override
  State<AccountSourcesPanel> createState() => _AccountSourcesPanelState();
}

class _AccountSourcesPanelState extends State<AccountSourcesPanel> {
  bool expanded = false;
  Timer? _overviewClock;
  String sort = 'remaining';
  final _loginStates = <String, String>{};
  AccountSourcesController get owner => widget.owner;

  @override
  void initState() {
    super.initState();
    owner.addListener(_observeLogin);
  }

  @override
  void didUpdateWidget(covariant AccountSourcesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.owner != owner) {
      oldWidget.owner.removeListener(_observeLogin);
      _loginStates.clear();
      owner.addListener(_observeLogin);
    }
  }

  void _observeLogin() {
    final refresh = <String>[];
    for (final source in owner.states) {
      final previous = _loginStates[source.id];
      _loginStates[source.id] = source.loginState;
      if (['starting', 'waiting'].contains(previous) &&
          source.loginState == 'succeeded' &&
          !owner.monitoring) {
        refresh.add(source.id);
      }
    }
    for (final id in refresh) {
      unawaited(owner.refresh(id));
    }
  }

  @override
  void dispose() {
    _overviewClock?.cancel();
    owner.removeListener(_observeLogin);
    super.dispose();
  }

  void _toggleOverview() {
    setState(() => expanded = !expanded);
    _overviewClock?.cancel();
    _overviewClock = expanded
        ? Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}))
        : null;
  }

  Map<String, String> _sourceChoices() {
    final states = owner.states
        .where((source) => !source.pendingRemoval)
        .toList();
    final aliases = states.map((source) => source.alias).toSet();
    final choices = <String, String>{};
    for (final source in states) {
      var label = source.alias;
      if (choices.containsKey(label)) {
        var suffix = 1;
        do {
          label = '${source.alias} · ${suffix++}';
        } while (aliases.contains(label) || choices.containsKey(label));
      }
      choices[label] = source.id;
    }
    return choices;
  }

  Future<void> _login([String? id]) => showMonitorInformation(
    context,
    titleKey: id == null
        ? 'accounts.sources.addTitle'
        : 'accounts.sources.loginTitle',
    title: id == null
        ? AppCopy.of(context).text('accounts.sources.addTitle')
        : AppCopy.of(context).text('accounts.sources.loginTitle'),
    builder: (_) => _SourceLoginEditor(owner: owner, sourceId: id),
  );

  Future<void> _details(String id) => showMonitorInformation(
    context,
    titleKey: 'accounts.sources.details',
    title: AppCopy.of(context).text('accounts.sources.details'),
    builder: (_) => ListenableBuilder(
      listenable: owner,
      builder: (context, _) {
        final source = owner.states.where((s) => s.id == id).firstOrNull;
        if (source == null) {
          return Text(AppCopy.of(context).text('accounts.sources.removed'));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(source.alias),
            Text(AppCopy.of(context).text('accounts.sources.separateDetails')),
            Text(
              AppCopy.of(context).text(
                'accounts.sources.loginState',
                args: {'state': _loginLabel(context, source.loginState)},
              ),
            ),
            if (source.usage != null) ...[
              Text(
                AppCopy.of(context).text(
                  'accounts.sources.account',
                  args: {
                    'value':
                        source.usage!.email ??
                        AppCopy.of(context).text('common.unknown'),
                  },
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'accounts.sources.plan',
                  args: {
                    'value':
                        source.usage!.plan ??
                        AppCopy.of(context).text('common.unknown'),
                  },
                ),
              ),
              Text(
                AppCopy.of(context).text(
                  'accounts.sources.observedAt',
                  args: {
                    'value': AppCopy.of(
                      context,
                    ).dateTime(source.usage!.fetchedAt, includeSeconds: true),
                  },
                ),
              ),
            ],
            if (source.errorKind != null)
              Text(_sourceErrorLabel(context, source.errorKind)),
          ],
        );
      },
    ),
  );

  Future<void> _rename(AccountSourceState source) => showMonitorInformation(
    context,
    titleKey: 'accounts.sources.renameTitle',
    title: AppCopy.of(context).text('accounts.sources.renameTitle'),
    builder: (_) => _SourceRename(owner: owner, source: source),
  );

  Future<void> _remove(AccountSourceState source) => showMonitorInformation(
    context,
    titleKey: 'accounts.sources.removeTitle',
    title: AppCopy.of(context).text('accounts.sources.removeTitle'),
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppCopy.of(context).text(
            'accounts.sources.removePrompt',
            args: {'alias': source.alias},
          ),
        ),
        const SizedBox(height: 12),
        FButton(
          key: const ValueKey('source-remove-confirm'),
          onPress: source.isCurrent
              ? null
              : () async {
                  await owner.remove(source.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
          child: Text(
            AppCopy.of(context).text('accounts.sources.confirmRemove'),
          ),
        ),
      ],
    ),
  );

  double? _sortValue(AccountSourceState source) {
    final windows =
        source.usage?.buckets.expand((b) => b.windows) ?? const <UsageWindow>[];
    final values = sort == 'remaining'
        ? windows
              .where((w) => w.usedPercent != null)
              .map((w) => 100 - w.usedPercent!)
        : windows
              .where((w) => w.resetsAt != null)
              .map((w) => w.resetsAt!.millisecondsSinceEpoch.toDouble());
    return values.isEmpty ? null : values.reduce(math.min);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: owner,
    builder: (context, _) {
      final selected = owner.selected;
      final canEdit = owner.canMutateCatalog;
      final choices = _sourceChoices();
      final states = owner.states.toList()
        ..sort((a, b) {
          final av = _sortValue(a), bv = _sortValue(b);
          if (av == null) return bv == null ? a.alias.compareTo(b.alias) : 1;
          return bv == null ? -1 : av.compareTo(bv);
        });
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppCopy.of(context).text('accounts.sources.title'),
            style: context.theme.typography.body.sm,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (choices.isNotEmpty)
                SizedBox(
                  width: 192,
                  child: MonitorChoice(
                    key: const ValueKey('account-source-selector'),
                    label: AppCopy.of(context).text('accounts.sources.title'),
                    showLabel: false,
                    value: owner.selectedId,
                    items: choices,
                    onChanged: owner.select,
                  ),
                ),
              if (owner.states.isNotEmpty)
                FButton(
                  key: const ValueKey('toggle-source-overview'),
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.ghost,
                  selected: expanded,
                  prefix: Icon(
                    expanded
                        ? FLucideIcons.chevronDown
                        : FLucideIcons.layoutGrid,
                    size: 16,
                  ),
                  onPress: _toggleOverview,
                  child: Text(
                    AppCopy.of(context).text(
                      'accounts.sources.overviewCount',
                      args: {'count': owner.states.length},
                    ),
                  ),
                ),
              FButton(
                key: const ValueKey('add-account-source'),
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                prefix: const Icon(FLucideIcons.plus, size: 16),
                onPress: canEdit ? () => _login() : null,
                child: Text(AppCopy.of(context).text('accounts.sources.add')),
              ),
              if (selected != null)
                MonitorIconAction(
                  key: const ValueKey('pin-selected-source'),
                  label: selected.id == owner.pinnedId
                      ? AppCopy.of(context)
                            .text('accounts.sources.pinnedSelected')
                      : AppCopy.of(context)
                            .text('accounts.sources.pinSelected'),
                  icon: FLucideIcons.pin,
                  onPress: owner.canOperate && !selected.pendingRemoval
                      ? () => owner.pin(selected.id)
                      : null,
                ),
              if (owner.pinned != null)
                Text(
                  AppCopy.of(context).text(
                    'accounts.sources.trayAlias',
                    args: {'alias': owner.pinned!.alias},
                  ),
                  style: context.theme.typography.body.sm,
                ),
              if (selected != null)
                FPopoverMenu(
                  menuAnchor: Alignment.topRight,
                  childAnchor: Alignment.bottomRight,
                  menuBuilder: (context, popover, _) => [
                    FItemGroup(
                      children: [
                        FItem(
                          key: const ValueKey('source-details'),
                          title: Text(
                            AppCopy.of(context)
                                .text('accounts.sources.details'),
                          ),
                          onPress: () {
                            popover.hide();
                            _details(selected.id);
                          },
                        ),
                        FItem(
                          key: const ValueKey('source-rename'),
                          title: Text(
                            AppCopy.of(context).text('accounts.sources.rename'),
                          ),
                          onPress: canEdit
                              ? () {
                                  popover.hide();
                                  _rename(selected);
                                }
                              : null,
                        ),
                        if (!selected.isCurrent) ...[
                          FItem(
                            key: const ValueKey('source-login'),
                            title: Text(
                              selected.loggingIn
                                  ? AppCopy.of(context)
                                        .text('accounts.sources.loginProgress')
                                  : AppCopy.of(context)
                                        .text('accounts.sources.loginRetry'),
                            ),
                            onPress: canEdit
                                ? () {
                                    popover.hide();
                                    _login(selected.id);
                                  }
                                : null,
                          ),
                          FItem(
                            key: const ValueKey('source-remove'),
                            title: Text(
                              AppCopy.of(context)
                                  .text('accounts.sources.remove'),
                            ),
                            onPress: canEdit
                                ? () {
                                    popover.hide();
                                    _remove(selected);
                                  }
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ],
                  builder: (_, popover, _) => MonitorIconAction(
                    key: const ValueKey('source-management'),
                    label: AppCopy.of(context).text('accounts.sources.manage'),
                    icon: FLucideIcons.ellipsis,
                    onPress: popover.toggle,
                  ),
                ),
            ],
          ),
          if (choices.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(AppCopy.of(context).text('accounts.sources.empty')),
            ),
          if (owner.states.any((s) => s.loggingIn)) ...[
            const SizedBox(height: 4),
            for (final source in owner.states.where((s) => s.loggingIn))
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                onPress: () => _login(source.id),
                child: Text(
                  AppCopy.of(context).text(
                    'accounts.sources.progressLine',
                    args: {
                      'alias': source.alias,
                      'state': AppCopy.of(context)
                          .text(switch (source.loginState) {
                            'cancelling' => 'accounts.sources.cancellingShort',
                            'cancel_failed' =>
                              'accounts.sources.cancelUnknownShort',
                            _ => 'accounts.sources.loginShort',
                          }),
                    },
                  ),
                ),
              ),
          ],
          for (final source in owner.states.where((s) => s.pendingRemoval))
            FButton(
              key: ValueKey('retry-remove-${source.id}'),
              mainAxisSize: MainAxisSize.min,
              variant: FButtonVariant.ghost,
              onPress: owner.canOperate ? () => owner.remove(source.id) : null,
              child: Text(
                AppCopy.of(context).text(
                  'accounts.sources.retryRemoval',
                  args: {'alias': source.alias},
                ),
              ),
            ),
          if (owner.catalogError != null)
            Text(AppCopy.of(context).text('accounts.sources.catalogError')),
          if (owner.operationError != null)
            Text(AppCopy.of(context).text('accounts.sources.operationError')),
          if (owner.shutdownState == 'pending')
            Text(AppCopy.of(context).text('accounts.sources.shutdownPending')),
          if (owner.shutdownState == 'failed')
            Text(AppCopy.of(context).text('accounts.sources.shutdownFailed')),
          if (expanded && owner.states.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(AppCopy.of(context).text('accounts.sources.separate')),
                MonitorChoice(
                  key: const ValueKey('source-overview-sort'),
                  inline: true,
                  label: AppCopy.of(context).text('accounts.sources.sort'),
                  value: sort,
                  items: {
                    AppCopy.of(context).text('accounts.remainingQuota'):
                        'remaining',
                    AppCopy.of(context).text('accounts.nextReset'): 'reset',
                  },
                  onChanged: (value) => setState(() => sort = value),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900 ? 2 : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * 12) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final source in states)
                      SizedBox(
                        width: width,
                        child: _SourceCard(
                          key: ValueKey('source-overview-${source.id}'),
                          source: source,
                          owner: owner,
                          onDetails: () => _details(source.id),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 8),
        ],
      );
    },
  );
}

String _loginLabel(BuildContext context, String state) => switch (state) {
  'starting' => AppCopy.of(context).text('accounts.login.starting'),
  'waiting' => AppCopy.of(context).text('accounts.login.waiting'),
  'cancelling' => AppCopy.of(context).text('accounts.login.cancelling'),
  'cancel_failed' => AppCopy.of(context).text('accounts.login.cancel_failed'),
  'removing' => AppCopy.of(context).text('accounts.login.removing'),
  'succeeded' => AppCopy.of(context).text('accounts.login.succeeded'),
  'cancelled' => AppCopy.of(context).text('accounts.login.cancelled'),
  'timed_out' => AppCopy.of(context).text('accounts.login.timed_out'),
  'failed' => AppCopy.of(context).text('accounts.login.failed'),
  _ => AppCopy.of(context).text('accounts.login.idle'),
};

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    super.key,
    required this.source,
    required this.owner,
    required this.onDetails,
  });
  final AccountSourceState source;
  final AccountSourcesController owner;
  final VoidCallback onDetails;
  @override
  Widget build(BuildContext context) {
    final now = owner.currentTime;
    final buckets = source.usage?.buckets ?? const <UsageBucket>[];
    final age = source.usage == null
        ? null
        : math.max(0, now.difference(source.usage!.fetchedAt).inMinutes);
    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FButton(
                  key: ValueKey('source-select-${source.id}'),
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.ghost,
                  selected: source.id == owner.selectedId,
                  onPress: source.pendingRemoval
                      ? null
                      : () => owner.select(source.id),
                  child: Text(source.alias),
                ),
                MonitorIconAction(
                  key: ValueKey('source-pin-${source.id}'),
                  label: source.id == owner.pinnedId
                      ? AppCopy.of(context).text('accounts.sources.pinned')
                      : AppCopy.of(context).text('accounts.sources.pin'),
                  icon: FLucideIcons.pin,
                  onPress: source.pendingRemoval
                      ? null
                      : () => owner.pin(source.id),
                ),
                MonitorIconAction(
                  label: AppCopy.of(context)
                      .text('accounts.sources.viewDetails'),
                  icon: FLucideIcons.info,
                  onPress: onDetails,
                ),
              ],
            ),
            Text(
              source.pendingRemoval
                  ? AppCopy.of(context).text('accounts.sources.removalUnknown')
                  : age == null
                  ? AppCopy.of(context).text('accounts.sources.unobserved')
                  : AppCopy.of(context).text(
                      'accounts.sources.age',
                      args: {
                        'minutes': age,
                        'stale': owner.isStale(source)
                            ? AppCopy.of(context).text('accounts.sources.stale')
                            : '',
                      },
                    ),
              style: context.theme.typography.body.sm,
            ),
            if (source.errorKind != null)
              Text(
                _sourceErrorLabel(context, source.errorKind),
                style: context.theme.typography.body.sm,
              ),
            if (source.loggingIn) Text(_loginLabel(context, source.loginState)),
            if (source.pendingRemoval)
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                onPress: owner.canOperate
                    ? () => owner.remove(source.id)
                    : null,
                child: Text(
                  AppCopy.of(context).text('accounts.sources.retryCleanup'),
                ),
              ),
            const SizedBox(height: 6),
            Text(AppCopy.of(context).text('accounts.remainingQuota')),
            MonitorRingChart(
              inspectionIdentity: (source.id, source.generation, 'remaining'),
              bars: [
                for (final bucket in buckets)
                  for (final w in bucket.windows)
                    ChartBar(
                      label: buckets.length > 1
                          ? '${bucket.label} · ${quotaWindowLabel(AppCopy.of(context), w)}'
                          : quotaWindowLabel(AppCopy.of(context), w),
                      value:
                          w.usedPercent == null ||
                              !w.usedPercent!.isFinite ||
                              w.usedPercent! < 0 ||
                              w.usedPercent! > 100
                          ? null
                          : 100 - w.usedPercent!,
                      identity: (bucket.id, w.durationMinutes, w.label),
                    ),
              ],
              hoverDetails: false,
              showInspection: false,
            ),
            const SizedBox(height: 8),
            Text(AppCopy.of(context).text('accounts.sources.resetHours')),
            MonitorBarChart(
              inspectionIdentity: (source.id, source.generation, 'reset'),
              bars: [
                for (final bucket in buckets)
                  for (final w in bucket.windows)
                    ChartBar(
                      label: buckets.length > 1
                          ? '${bucket.label} · ${quotaWindowLabel(AppCopy.of(context), w)}'
                          : quotaWindowLabel(AppCopy.of(context), w),
                      value: w.resetsAt == null || !w.resetsAt!.isAfter(now)
                          ? null
                          : w.resetsAt!.difference(now).inMinutes / 60,
                      detail: w.resetsAt == null
                          ? AppCopy.of(context).text('accounts.resetUnknown')
                          : !w.resetsAt!.isAfter(now)
                          ? AppCopy.of(context).text('accounts.expired')
                          : AppCopy.of(context).text(
                              'accounts.sources.localReset',
                              args: {
                                'time': AppCopy.of(context)
                                    .dateTime(w.resetsAt, includeSeconds: true),
                              },
                            ),
                      identity: (bucket.id, w.durationMinutes, w.label),
                    ),
              ],
              horizontal: true,
              compactMeters: true,
              hoverDetails: false,
              showInspection: false,
              unit: AppCopy.of(context).text('accounts.hours'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceLoginEditor extends StatefulWidget {
  const _SourceLoginEditor({required this.owner, this.sourceId});
  final AccountSourcesController owner;
  final String? sourceId;
  @override
  State<_SourceLoginEditor> createState() => _SourceLoginEditorState();
}

class _SourceLoginEditorState extends State<_SourceLoginEditor> {
  late String? id = widget.sourceId;
  String alias = '';
  bool working = false;
  Future<void> _start() async {
    if (working) return;
    setState(() => working = true);
    try {
      final created = id ?? await widget.owner.create(alias);
      if (created == null) return;
      id = created;
      await widget.owner.login(created);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.owner,
    builder: (context, _) {
      final source = widget.owner.states.where((s) => s.id == id).firstOrNull;
      final allowed =
          widget.owner.canOperate && widget.owner.catalogError == null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(AppCopy.of(context).text('accounts.sources.loginExplanation')),
          const SizedBox(height: 12),
          if (id == null)
            FTextField(
              key: const ValueKey('source-alias-input'),
              label: Text(AppCopy.of(context).text('accounts.sources.alias')),
              control: FTextFieldControl.managed(
                onChange: (value) => setState(() => alias = value.text),
              ),
            )
          else
            Text(
              source?.alias ??
                  AppCopy.of(context).text('accounts.sources.removedShort'),
            ),
          const SizedBox(height: 12),
          if (working || source?.loggingIn == true) const FProgress(),
          Text(
            working && source == null
                ? AppCopy.of(context).text('accounts.sources.creating')
                : _loginLabel(context, source?.loginState ?? 'idle'),
          ),
          if (widget.owner.capability?.managedLogin == false)
            Text(AppCopy.of(context).text('accounts.sources.unsupported')),
          if (source?.errorKind != null)
            Text(_sourceErrorLabel(context, source!.errorKind)),
          if (widget.owner.operationError != null)
            Text(
              AppCopy.of(context).text('accounts.sources.operationUnavailable'),
            ),
          const SizedBox(height: 12),
          if (source?.loggingIn == true)
            FButton(
              key: const ValueKey('source-login-cancel'),
              onPress: () => widget.owner.cancelLogin(id!),
              child: Text(
                source?.loginState == 'cancel_failed'
                    ? AppCopy.of(context).text('accounts.sources.retryCancel')
                    : AppCopy.of(context).text('accounts.sources.cancelLogin'),
              ),
            )
          else
            FButton(
              key: ValueKey(
                id == null ? 'source-add-login' : 'source-login-retry',
              ),
              onPress:
                  !allowed ||
                      working ||
                      widget.owner.states.any((state) => state.loggingIn) ||
                      (id == null && alias.trim().isEmpty) ||
                      source?.isCurrent == true ||
                      source?.pendingRemoval == true
                  ? null
                  : _start,
              child: Text(
                id == null
                    ? AppCopy.of(context).text('accounts.sources.createLogin')
                    : AppCopy.of(context).text('accounts.sources.reopenLogin'),
              ),
            ),
          if (source?.loginState == 'succeeded') ...[
            Text(AppCopy.of(context).text('accounts.sources.loginComplete')),
            const SizedBox(height: 8),
            FButton(
              key: const ValueKey('source-login-name'),
              onPress: !allowed
                  ? null
                  : () => showMonitorInformation(
                      context,
                      titleKey: 'accounts.sources.nameTitle',
                      title: AppCopy.of(context)
                          .text('accounts.sources.nameTitle'),
                      builder: (_) =>
                          _SourceRename(owner: widget.owner, source: source!),
                    ),
              child: Text(
                AppCopy.of(context).text('accounts.sources.confirmName'),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _SourceRename extends StatefulWidget {
  const _SourceRename({required this.owner, required this.source});
  final AccountSourcesController owner;
  final AccountSourceState source;
  @override
  State<_SourceRename> createState() => _SourceRenameState();
}

class _SourceRenameState extends State<_SourceRename> {
  String alias = '';
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        AppCopy.of(context).text(
          'accounts.sources.currentAlias',
          args: {'alias': widget.source.alias},
        ),
      ),
      FTextField(
        key: const ValueKey('source-rename-input'),
        label: Text(AppCopy.of(context).text('accounts.sources.newAlias')),
        control: FTextFieldControl.managed(
          onChange: (value) => setState(() => alias = value.text),
        ),
      ),
      const SizedBox(height: 12),
      FButton(
        key: const ValueKey('source-rename-save'),
        onPress: alias.trim().isEmpty
            ? null
            : () {
                widget.owner.rename(widget.source.id, alias);
                Navigator.of(context).pop();
              },
        child: Text(AppCopy.of(context).text('accounts.sources.saveAlias')),
      ),
    ],
  );
}

// Public source failure kinds are presentation state, not translated transport data.
String _sourceErrorLabel(BuildContext context, String? kind) =>
    AppCopy.of(context).text(switch (kind) {
      'auth_required' || 'auth_failed' => 'accounts.sourceError.auth',
      'network' => 'accounts.sourceError.network',
      'rate_limited' => 'accounts.sourceError.rate',
      'timeout' => 'accounts.sourceError.timeout',
      'unsupported' || 'isolation_failed' => 'accounts.sourceError.unsupported',
      'cancelled' => 'accounts.sourceError.cancelled',
      'busy' => 'accounts.sourceError.busy',
      _ => 'accounts.sourceError.unavailable',
    });
