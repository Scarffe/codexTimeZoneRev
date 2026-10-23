import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// One same-window, scrollable destination for permitted dynamic facts only.
Future<void> showMonitorInformation(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭详情',
  pageBuilder: (context, _, _) => Padding(
    padding: const EdgeInsets.all(16),
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: FCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: context.theme.typography.body.lg),
                const SizedBox(height: 12),
                Flexible(child: SingleChildScrollView(child: builder(context))),
                const SizedBox(height: 12),
                FButton(
                  key: const ValueKey('monitor-information-close'),
                  variant: FButtonVariant.outline,
                  onPress: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

class MonitorInformationFact extends StatelessWidget {
  const MonitorInformationFact({
    super.key,
    required this.label,
    required this.value,
    this.copyable = false,
  });
  final String label, value;
  final bool copyable;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label：$value'),
        if (copyable)
          FButton(
            mainAxisSize: MainAxisSize.min,
            variant: FButtonVariant.ghost,
            prefix: const Icon(FLucideIcons.copy, size: 14),
            onPress: () => Clipboard.setData(ClipboardData(text: value)),
            child: Text('复制$label'),
          ),
      ],
    ),
  );
}
