import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Compact actions retain native focus, an accessible name and a hover label.
class MonitorIconAction extends StatelessWidget {
  const MonitorIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPress,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FTooltip(
    tipBuilder: (context, _) => Text(label),
    child: FButton.raw(
      semanticsLabel: label,
      semanticsTooltip: label,
      variant: FButtonVariant.ghost,
      onPress: onPress,
      child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 18)),
    ),
  );
}

/// Local disclosure state survives refreshes and workspace switches.
class MonitorDisclosure extends StatefulWidget {
  const MonitorDisclosure({
    super.key,
    required this.label,
    required this.toggleKey,
    required this.child,
  });
  final String label;
  final Key toggleKey;
  final Widget child;

  @override
  State<MonitorDisclosure> createState() => _MonitorDisclosureState();
}

class _MonitorDisclosureState extends State<MonitorDisclosure> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          expanded: expanded,
          child: FButton(
            key: widget.toggleKey,
            mainAxisSize: MainAxisSize.min,
            variant: FButtonVariant.ghost,
            onPress: () => setState(() => expanded = !expanded),
            prefix: Icon(
              expanded ? FLucideIcons.chevronDown : FLucideIcons.chevronRight,
            ),
            child: Flexible(child: Text(widget.label)),
          ),
        ),
      ),
      if (expanded)
        Padding(padding: const EdgeInsets.only(top: 8), child: widget.child),
    ],
  );
}
