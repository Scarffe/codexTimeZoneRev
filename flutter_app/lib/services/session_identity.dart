/// Presentation only. Never use these labels as routing or storage keys.
String sessionProjectName(String? path) =>
    (path ?? '')
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull ??
    '';

String sessionIdentitySuffix(String id) =>
    id.length > 8 ? id.substring(id.length - 8) : id;

String readableSessionName({
  String? title,
  String? project,
  bool english = false,
}) {
  final clean = title?.trim();
  if (clean != null && clean.isNotEmpty) return clean;
  final name = sessionProjectName(project);
  final unnamed = english ? 'Untitled conversation' : '未命名会话';
  return name.isEmpty || name == '__unknown__' || name == 'unknown'
      ? unnamed
      : '$unnamed · $name';
}
