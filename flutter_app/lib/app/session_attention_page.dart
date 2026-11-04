import '../l10n/copy_sessions.dart';
import '../l10n/app_copy.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../services/session_attention.dart';
import '../services/session_identity.dart';
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
  String? _path;
  Object? _actionError;
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
      if (mounted) setState(() => _actionError = error);
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
              AppCopy.of(context).text(
                'sessions.watchedUnread',
                args: {'p0': c.watches.length, 'p1': c.unreadCount},
              ),
              style: context.theme.typography.display.sm,
            ),
            Text(
              AppCopy.of(context)
                  .text('sessions.onlyExplicitlyWatchedSessionsAreReadRecent'),
            ),
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
                        child: Text(
                          AppCopy.of(context)
                              .text('sessions.listAvailableSessions'),
                        ),
                      ),
                    ),
                    if (_listed && c.availableSessions.isEmpty)
                      Text(
                        AppCopy.of(context)
                            .text('sessions.noSessionsAvailable'),
                      ),
                    if (c.availableSessions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      FSelect<String>.search(
                        key: const ValueKey('attention-selector'),
                        label: Text(
                          AppCopy.of(context).text('sessions.localSessions'),
                        ),
                        items: {
                          for (final (index, s) in c.availableSessions.indexed)
                            '${s.title} · ${sessionIdentitySuffix(s.id)} · ${index + 1}':
                                s.path,
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
                        label: Text(
                          AppCopy.of(context).text('sessions.aliasOptional'),
                        ),
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
                            c.watches.length >= 8
                                ? AppCopy.of(context)
                                      .text('sessions.watchLimitReached')
                                : AppCopy.of(context).text('sessions.addWatch'),
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
                AppCopy.of(context).text(
                  'sessions.changesNotSaved',
                  args: {
                    'p0': AppCopy.of(context)
                        .attentionDiagnostic(_actionError!),
                  },
                ),
                key: const ValueKey('attention-action-error'),
              ),
            if (c.error != null)
              Text(
                AppCopy.of(context).attentionDiagnostic(c.error!),
                key: const ValueKey('attention-error'),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in [
                  ('unread', AppCopy.of(context).text('sessions.unread')),
                  ('active', AppCopy.of(context).text('sessions.watching')),
                  ('all', AppCopy.of(context).text('sessions.all')),
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
                  child: Text(
                    AppCopy.of(context).text('sessions.markAllAsRead'),
                  ),
                ),
              ],
            ),
            if (_filter != 'unread') ...[
              if (watches.isEmpty)
                Text(
                  _filter == 'active'
                      ? AppCopy.of(context).text('sessions.noActiveWatches')
                      : AppCopy.of(context).text('sessions.noWatchesAdded'),
                ),
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
                            AppCopy.of(context).attentionWatchTitle(item.watch),
                            style: context.theme.typography.body.lg,
                          ),
                          Text(
                            '${item.watch.enabled ? AppCopy.of(context).text('sessions.watching') : AppCopy.of(context).text('sessions.paused')} · ${_status(item.status)}',
                          ),
                          Text(item.expectedSessionId),
                          Text(item.path),
                          if (item.readError != null)
                            Text(
                              AppCopy.of(context).text(
                                'sessions.readFailedCurrentStatusUnknownTaskFailure',
                              ),
                            ),
                          if (item.catchingUp)
                            Text(
                              AppCopy.of(context).text(
                                'sessions.readingHistoryBaselineNotYetComplete',
                              ),
                            ),
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
                                  item.watch.enabled
                                      ? AppCopy.of(context)
                                            .text('sessions.pauseWatch')
                                      : AppCopy.of(context)
                                            .text('sessions.resumeWatch'),
                                ),
                              ),
                              FButton(
                                key: ValueKey('watch-remove-${item.key}'),
                                variant: FButtonVariant.ghost,
                                mainAxisSize: MainAxisSize.min,
                                onPress: _busy
                                    ? null
                                    : () => _run(() => c.unwatch(item.key)),
                                child: Text(
                                  AppCopy.of(context)
                                      .text('sessions.removeWatch'),
                                ),
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
                Text(
                  _filter == 'unread'
                      ? AppCopy.of(context).text('sessions.noUnreadReminders')
                      : AppCopy.of(context)
                            .text('sessions.noCompletionReminders'),
                ),
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
                            '${notice.read ? AppCopy.of(context).text('sessions.read') : AppCopy.of(context).text('sessions.unread')} · ${notice.title}',
                            style: context.theme.typography.body.lg,
                          ),
                          Text(
                            AppCopy.of(context).text(
                              'sessions.turnCompleted',
                              args: {
                                'p0': (AppCopy.of(context).isEnglish
                                    ? AppCopy.of(context).dateTime(
                                        notice.createdAt,
                                        includeSeconds: true,
                                      )
                                    : notice.createdAt.toLocal()),
                              },
                            ),
                          ),
                          Text(
                            AppCopy.of(context).text(
                              'sessions.sessionTurn',
                              args: {
                                'p0': notice.sessionId,
                                'p1': notice.turnId,
                              },
                            ),
                          ),
                          Text(notice.path),
                          Wrap(
                            spacing: 8,
                            children: [
                              FButton(
                                key: ValueKey('notice-open-${notice.id}'),
                                mainAxisSize: MainAxisSize.min,
                                onPress: () => widget.onOpenNotice(notice),
                                child: Text(
                                  AppCopy.of(context).text(
                                    'sessions.openOriginalSessionAnalysis',
                                  ),
                                ),
                              ),
                              if (!notice.read)
                                FButton(
                                  key: ValueKey('notice-read-${notice.id}'),
                                  mainAxisSize: MainAxisSize.min,
                                  variant: FButtonVariant.ghost,
                                  onPress: _busy
                                      ? null
                                      : () => _run(() => c.markRead(notice.id)),
                                  child: Text(
                                    AppCopy.of(context)
                                        .text('sessions.markAsRead'),
                                  ),
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
    SessionAttentionStatus.running => AppCopy.of(
      context,
    ).text('sessions.turnRunning'),
    SessionAttentionStatus.completed => AppCopy.of(
      context,
    ).text('sessions.turnCompleted2'),
    SessionAttentionStatus.cancelled => AppCopy.of(
      context,
    ).text('sessions.cancelled'),
    SessionAttentionStatus.unknown => AppCopy.of(
      context,
    ).text('sessions.statusUnknown'),
  };
}
