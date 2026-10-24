import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/account_sources.dart';
import '../services/account_usage.dart';
import '../state/account_sources_controller.dart';
import 'monitor_charts.dart';
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
    owner.removeListener(_observeLogin);
    super.dispose();
  }

  Future<void> _login([String? id]) => showMonitorInformation(
    context,
    title: id == null ? '添加监控来源' : '官方登录',
    builder: (_) => _SourceLoginEditor(owner: owner, sourceId: id),
  );

  Future<void> _details(String id) => showMonitorInformation(
    context,
    title: '来源详情',
    builder: (_) => ListenableBuilder(
      listenable: owner,
      builder: (context, _) {
        final source = owner.states.where((s) => s.id == id).firstOrNull;
        if (source == null) return const Text('来源已移除。');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(source.alias),
            const Text('来源选择仅改变额度监控；本地会话仍独立采集。'),
            if (source.isCurrent) const Text('默认来源受保护：不支持登录、退出登录或移除。'),
            Text('登录状态：${_loginLabel(source.loginState)}'),
            if (source.usage != null) ...[
              Text('账号：${source.usage!.email ?? '未知'}'),
              Text('方案：${source.usage!.plan ?? '未知'}'),
              Text('观测时间：${source.usage!.fetchedAt.toLocal()}'),
            ],
            if (source.errorKind != null)
              Text(sourceErrorMessage(source.errorKind)),
          ],
        );
      },
    ),
  );

  Future<void> _rename(AccountSourceState source) => showMonitorInformation(
    context,
    title: '重命名来源',
    builder: (_) => _SourceRename(owner: owner, source: source),
  );

  Future<void> _remove(AccountSourceState source) => showMonitorInformation(
    context,
    title: '移除监控来源',
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('移除“${source.alias}”及其由本应用管理的登录目录。'),
        const SizedBox(height: 12),
        FButton(
          key: const ValueKey('source-remove-confirm'),
          onPress: source.isCurrent
              ? null
              : () async {
                  await owner.remove(source.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
          child: const Text('确认移除'),
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
      final canEdit = owner.canOperate && owner.catalogError == null;
      final states = owner.states.toList()
        ..sort((a, b) {
          final av = _sortValue(a), bv = _sortValue(b);
          if (av == null) return bv == null ? a.alias.compareTo(b.alias) : 1;
          return bv == null ? -1 : av.compareTo(bv);
        });
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 192,
                child: MonitorChoice(
                  key: const ValueKey('account-source-selector'),
                  label: '额度来源',
                  value: owner.selectedId,
                  items: {
                    for (var i = 0; i < owner.states.length; i++)
                      if (!owner.states[i].pendingRemoval)
                        '${owner.states[i].alias}${owner.states.where((s) => s.alias == owner.states[i].alias).length > 1 ? ' · ${i + 1}' : ''}':
                            owner.states[i].id,
                  },
                  onChanged: owner.select,
                ),
              ),
              FButton(
                key: const ValueKey('toggle-source-overview'),
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                selected: expanded,
                prefix: Icon(
                  expanded ? FLucideIcons.chevronDown : FLucideIcons.layoutGrid,
                  size: 16,
                ),
                onPress: () => setState(() => expanded = !expanded),
                child: Text('总览 (${owner.states.length})'),
              ),
              FButton(
                key: const ValueKey('add-account-source'),
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                prefix: const Icon(FLucideIcons.plus, size: 16),
                onPress: canEdit ? () => _login() : null,
                child: const Text('添加'),
              ),
              MonitorIconAction(
                key: const ValueKey('pin-selected-source'),
                label: selected?.id == owner.pinnedId
                    ? '此来源已固定到托盘'
                    : '将此来源固定到托盘',
                icon: FLucideIcons.pin,
                onPress:
                    owner.canOperate &&
                        selected != null &&
                        !selected.pendingRemoval
                    ? () => owner.pin(selected.id)
                    : null,
              ),
              Text(
                '托盘：${owner.pinned?.alias ?? '未知来源'}',
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
                          title: const Text('来源详情'),
                          onPress: () {
                            popover.hide();
                            _details(selected.id);
                          },
                        ),
                        FItem(
                          key: const ValueKey('source-rename'),
                          title: const Text('重命名'),
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
                              selected.loggingIn ? '查看登录进度' : '官方登录 / 重试',
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
                            title: const Text('移除来源'),
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
                    label: '管理当前监控来源',
                    icon: FLucideIcons.ellipsis,
                    onPress: popover.toggle,
                  ),
                ),
            ],
          ),
          if (owner.states.any((s) => s.loggingIn)) ...[
            const SizedBox(height: 4),
            for (final source in owner.states.where((s) => s.loggingIn))
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                onPress: () => _login(source.id),
                child: Text(
                  '${source.alias} · ${switch (source.loginState) {
                    'cancelling' => '取消登录确认中',
                    'cancel_failed' => '取消登录待确认',
                    _ => '官方登录进行中',
                  }} · 查看进度',
                ),
              ),
          ],
          for (final source in owner.states.where((s) => s.pendingRemoval))
            FButton(
              key: ValueKey('retry-remove-${source.id}'),
              mainAxisSize: MainAxisSize.min,
              variant: FButtonVariant.ghost,
              onPress: owner.canOperate ? () => owner.remove(source.id) : null,
              child: Text('${source.alias} · 清理未确认 · 重试移除'),
            ),
          if (owner.catalogError != null)
            const Text('来源目录不可用，原文件已保留；添加与登录已停用。'),
          if (owner.operationError != null) const Text('来源操作未完成，请检查环境后重试。'),
          if (expanded) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('来源选择仅改变额度监控；本地会话独立采集。'),
                MonitorChoice(
                  key: const ValueKey('source-overview-sort'),
                  inline: true,
                  label: '排序',
                  value: sort,
                  items: const {'剩余额度': 'remaining', '下次重置': 'reset'},
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

String _loginLabel(String state) => switch (state) {
  'starting' => '正在准备官方登录…',
  'waiting' => '等待官方浏览器登录；完成后此处会自动更新。',
  'cancelling' => '正在等待取消登录确认…',
  'cancel_failed' => '取消登录未确认，请重试取消。',
  'removing' => '来源清理未确认，可重试移除。',
  'succeeded' => '登录已完成。',
  'cancelled' => '登录已取消。',
  'timed_out' => '登录超时，请重试。',
  'failed' => '登录未完成，请重试。',
  _ => '尚未开始登录。',
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
    final now = DateTime.now();
    final windows =
        source.usage?.buckets.expand((b) => b.windows).toList() ??
        const <UsageWindow>[];
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
                  label: source.id == owner.pinnedId ? '已固定到托盘' : '固定到托盘',
                  icon: FLucideIcons.pin,
                  onPress: source.pendingRemoval
                      ? null
                      : () => owner.pin(source.id),
                ),
                MonitorIconAction(
                  label: '查看来源详情',
                  icon: FLucideIcons.info,
                  onPress: onDetails,
                ),
              ],
            ),
            Text(
              source.pendingRemoval
                  ? '来源清理未确认 · 额度已停止展示'
                  : age == null
                  ? '尚无观测 · 额度未知'
                  : '观测于 $age 分钟前${owner.isStale(source) ? ' · 数据已过期' : ''}',
              style: context.theme.typography.body.sm,
            ),
            if (source.errorKind != null)
              Text(
                sourceErrorMessage(source.errorKind),
                style: context.theme.typography.body.sm,
              ),
            if (source.loggingIn) Text(_loginLabel(source.loginState)),
            if (source.pendingRemoval)
              FButton(
                mainAxisSize: MainAxisSize.min,
                variant: FButtonVariant.ghost,
                onPress: owner.canOperate
                    ? () => owner.remove(source.id)
                    : null,
                child: const Text('重试清理来源'),
              ),
            const SizedBox(height: 6),
            const Text('剩余额度'),
            MonitorBarChart(
              inspectionIdentity: (source.id, source.generation, 'remaining'),
              bars: [
                for (final w in windows)
                  ChartBar(
                    label: w.label,
                    value: w.usedPercent == null ? null : 100 - w.usedPercent!,
                    identity: (w.durationMinutes, w.label),
                  ),
              ],
              horizontal: true,
              compactMeters: true,
              unit: '%',
              maxValue: 100,
            ),
            const SizedBox(height: 8),
            const Text('距重置 · 小时'),
            MonitorBarChart(
              inspectionIdentity: (source.id, source.generation, 'reset'),
              bars: [
                for (final w in windows)
                  ChartBar(
                    label: w.label,
                    value: w.resetsAt == null || !w.resetsAt!.isAfter(now)
                        ? null
                        : w.resetsAt!.difference(now).inMinutes / 60,
                    detail: w.resetsAt == null
                        ? '重置时间未知'
                        : !w.resetsAt!.isAfter(now)
                        ? '到期 · 待查询'
                        : '本地重置时间：${w.resetsAt!.toLocal()}',
                    identity: (w.durationMinutes, w.label),
                  ),
              ],
              horizontal: true,
              compactMeters: true,
              unit: '小时',
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
          const Text('使用官方浏览器登录独立监控来源。此操作不会切换正在运行的 Codex 账号。'),
          const SizedBox(height: 12),
          if (id == null)
            FTextField(
              key: const ValueKey('source-alias-input'),
              label: const Text('来源别名'),
              control: FTextFieldControl.managed(
                onChange: (value) => setState(() => alias = value.text),
              ),
            )
          else
            Text(source?.alias ?? '来源已移除'),
          const SizedBox(height: 12),
          if (working || source?.loggingIn == true) const FProgress(),
          Text(
            working && source == null
                ? '正在检查安全登录环境并创建来源…'
                : _loginLabel(source?.loginState ?? 'idle'),
          ),
          if (widget.owner.capability?.managedLogin == false)
            const Text('当前环境不支持安全添加来源。'),
          if (source?.errorKind != null)
            Text(sourceErrorMessage(source!.errorKind)),
          if (widget.owner.operationError != null)
            const Text('无法完成来源操作，请检查环境后重试。'),
          const SizedBox(height: 12),
          if (source?.loggingIn == true)
            FButton(
              key: const ValueKey('source-login-cancel'),
              onPress: () => widget.owner.cancelLogin(id!),
              child: Text(
                source?.loginState == 'cancel_failed' ? '重试取消登录' : '取消登录',
              ),
            )
          else if (source?.loginState != 'succeeded')
            FButton(
              key: ValueKey(
                id == null ? 'source-add-login' : 'source-login-retry',
              ),
              onPress:
                  !allowed ||
                      working ||
                      (id == null && alias.trim().isEmpty) ||
                      source?.isCurrent == true ||
                      source?.pendingRemoval == true
                  ? null
                  : _start,
              child: Text(id == null ? '创建来源并打开官方登录' : '重新打开官方登录'),
            ),
          if (source?.loginState == 'succeeded') ...[
            const Text('官方登录流程已报告完成；额度观测独立更新，别名仅用于区分来源。'),
            const SizedBox(height: 8),
            FButton(
              key: const ValueKey('source-login-name'),
              onPress: !allowed
                  ? null
                  : () => showMonitorInformation(
                      context,
                      title: '命名监控来源',
                      builder: (_) =>
                          _SourceRename(owner: widget.owner, source: source!),
                    ),
              child: const Text('确认并命名来源'),
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
      Text('当前别名：${widget.source.alias}'),
      FTextField(
        key: const ValueKey('source-rename-input'),
        label: const Text('新的来源别名'),
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
        child: const Text('保存别名'),
      ),
    ],
  );
}
