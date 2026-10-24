import 'package:flutter/widgets.dart';

import '../state/account_usage_controller.dart';
import '../state/launcher_controller.dart';
import 'account_sources_panel.dart';
import 'account_usage_panel.dart';

class AccountsWorkspacePage extends StatelessWidget {
  const AccountsWorkspacePage({
    super.key,
    required this.usage,
    required this.launcher,
  });
  final AccountUsageController usage;
  final LauncherController launcher;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey('accounts-scroll'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('账号额度来源 · 与本机会话日志、独立 API 测速分别记录。'),
        const SizedBox(height: 12),
        if (usage.sources != null) AccountSourcesPanel(owner: usage.sources!),
        AccountUsagePanel(controller: usage, launcher: launcher),
        const SizedBox(height: 16),
      ],
    ),
  );
}
