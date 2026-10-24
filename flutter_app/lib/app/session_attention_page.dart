import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_attention.dart';
import '../state/session_attention_controller.dart';

class SessionAttentionPage extends StatefulWidget {
  const SessionAttentionPage({
    super.key,
    required this.controller,
    required this.onOpenNotice,
  });
  final SessionAttentionController controller;
  final ValueChanged<SessionAttentionNotice> onOpenNotice;
  @override
  State<SessionAttentionPage> createState() => _SessionAttentionPageState();
}

class _SessionAttentionPageState extends State<SessionAttentionPage> {
  String _filter = 'unread';
  String? _path, _actionError;
  bool _busy = false, _listed = false;
  String _alias = '';
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final notices = c.notices.where(
        (n) => _filter == 'all' || (_filter == 'unread' && !n.read),
      );
      final watches = c.items.where(
        (i) => _filter != 'active' || i.watch.enabled,
      );
      return SingleChildScrollView(
        key: const PageStorageKey('attention-scroll'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '明确关注 ${c.watches.length}/8 · 未读 ${c.unreadCount}',
              style: context.theme.typography.display.sm,
            ),
            const Text('只读取你明确关注的会话；不会根据最近活动自动添加。新关注先建立基线，历史完成不产生提醒。'),
            const SizedBox(height: 12),
            FCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FButton(
                        key: const ValueKey('attention-refresh'),
                        mainAxisSize: MainAxisSize.min,
                        onPress: _busy
                            ? null
                            : () => _run(() async {
                                await c.refreshSessions();
                                if (mounted) setState(() => _listed = true);
                              }),
                        child: const Text('列出可关注会话'),
                      ),
                    ),
                    if (_listed && c.availableSessions.isEmpty)
                      const Text('暂无可选择的会话。'),
                    if (c.availableSessions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      FSelect<String>.search(
                        key: const ValueKey('attention-selector'),
                        label: const Text('本机会话'),
                        items: {
                          for (final (index, s) in c.availableSessions.indexed)
                            '${s.title} · ${s.id} · ${index + 1}': s.path,
                        },
                        control: FSelectControl.lifted(
                          value: _path,
                          onChange: (value) => setState(() => _path = value),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FTextField(
                        key: const ValueKey('attention-alias'),
                        control: FTextFieldControl.managed(
                          onChange: (value) => _alias = value.text,
                        ),
                        label: const Text('别名（可选）'),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FButton(
                          key: const ValueKey('attention-add'),
                          mainAxisSize: MainAxisSize.min,
                          onPress:
                              _busy || _path == null || c.watches.length >= 8
                              ? null
                              : () => _run(() async {
                                  final source = c.availableSessions.firstWhere(
                                    (s) => s.path == _path,
                                  );
                                  await c.watch(
                                    source.path,
                                    expectedId: source.id,
                                    alias: _alias.trim().isEmpty
                                        ? source.title
                                        : _alias.trim(),
                                  );
                                }),
                          child: Text(
                            c.watches.length >= 8 ? '已达到 8 个关注上限' : '添加关注',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_actionError != null)
              Text(
                '操作未保存：$_actionError',
                key: const ValueKey('attention-action-error'),
              ),
            if (c.error != null)
              Text(c.error!, key: const ValueKey('attention-error')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in [
                  ('unread', '未读'),
                  ('active', '关注中'),
                  ('all', '全部'),
                ])
                  Semantics(
                    selected: _filter == value,
                    child: FButton(
                      key: ValueKey('attention-filter-$value'),
                      selected: _filter == value,
                      variant: FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => setState(() => _filter = value),
                      child: Text(label),
                    ),
                  ),
                FButton(
                  key: const ValueKey('attention-read-all'),
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy || c.unreadCount == 0
                      ? null
                      : () => _run(c.markAllRead),
                  child: const Text('全部标为已读'),
                ),
              ],
            ),
            if (_filter != 'unread') ...[
              if (watches.isEmpty)
                Text(_filter == 'active' ? '暂无启用的关注。' : '尚未添加关注。'),
              for (final item in watches)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FCard(
                    key: ValueKey('watch-${item.key}'),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: context.theme.typography.body.lg,
                          ),
                          Text(
                            '${item.watch.enabled ? '关注中' : '已暂停'} · ${_status(item.status)}',
                          ),
                          Text(item.expectedSessionId),
                          Text(item.path),
                          if (item.readError != null)
                            const Text('读取失败 · 当前状态未知；不会推断任务失败。'),
                          if (item.catchingUp) const Text('正在读取历史 · 尚未建立完整基线'),
                          Wrap(
                            spacing: 8,
                            children: [
                              FButton(
                                key: ValueKey('watch-toggle-${item.key}'),
                                variant: FButtonVariant.ghost,
                                mainAxisSize: MainAxisSize.min,
                                onPress: _busy
                                    ? null
                                    : () => _run(
                                        () => c.setEnabled(
                                          item.key,
                                          !item.watch.enabled,
                                        ),
                                      ),
                                child: Text(
                                  item.watch.enabled ? '暂停关注' : '恢复关注',
                                ),
                              ),
                              FButton(
                                key: ValueKey('watch-remove-${item.key}'),
                                variant: FButtonVariant.ghost,
                                mainAxisSize: MainAxisSize.min,
                                onPress: _busy
                                    ? null
                                    : () => _run(() => c.unwatch(item.key)),
                                child: const Text('移除关注'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
            if (_filter != 'active') ...[
              if (notices.isEmpty)
                Text(_filter == 'unread' ? '暂无未读提醒。' : '暂无完成提醒。'),
              for (final notice in notices)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FCard(
                    key: ValueKey('notice-${notice.id}'),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${notice.read ? '已读' : '未读'} · ${notice.title}',
                            style: context.theme.typography.body.lg,
                          ),
                          Text('回合已完成 · ${notice.createdAt.toLocal()}'),
                          Text('会话 ${notice.sessionId} · 回合 ${notice.turnId}'),
                          Text(notice.path),
                          Wrap(
                            spacing: 8,
                            children: [
                              FButton(
                                key: ValueKey('notice-open-${notice.id}'),
                                mainAxisSize: MainAxisSize.min,
                                onPress: () => widget.onOpenNotice(notice),
                                child: const Text('打开原会话分析'),
                              ),
                              if (!notice.read)
                                FButton(
                                  key: ValueKey('notice-read-${notice.id}'),
                                  mainAxisSize: MainAxisSize.min,
                                  variant: FButtonVariant.ghost,
                                  onPress: _busy
                                      ? null
                                      : () => _run(() => c.markRead(notice.id)),
                                  child: const Text('标为已读'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 20),
          ],
        ),
      );
    },
  );
  String _status(SessionAttentionStatus value) => switch (value) {
    SessionAttentionStatus.running => '回合进行中',
    SessionAttentionStatus.completed => '回合已完成',
    SessionAttentionStatus.cancelled => '已取消',
    SessionAttentionStatus.unknown => '状态未知',
  };
}
