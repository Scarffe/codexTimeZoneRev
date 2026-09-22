import 'dart:convert';

class LauncherSettings {
  const LauncherSettings({
    this.mode = 'zone',
    this.zoneId = 'Asia/Shanghai',
    this.offset = 8,
    this.executable = '',
    this.dreamSkinCompatible = false,
  });

  final String mode;
  final String zoneId;
  final int offset;
  final String executable;
  final bool dreamSkinCompatible;

  factory LauncherSettings.fromJson(Map<String, dynamic> json) =>
      LauncherSettings(
        mode: json['mode'] as String,
        zoneId: json['zoneId'] as String,
        offset: json['offset'] as int,
        executable: json['executable'] as String,
        dreamSkinCompatible: json['dreamSkinCompatible'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'zoneId': zoneId,
    'offset': offset,
    'executable': executable,
    'dreamSkinCompatible': dreamSkinCompatible,
  };

  LauncherSettings copyWith({
    String? mode,
    String? zoneId,
    int? offset,
    String? executable,
    bool? dreamSkinCompatible,
  }) => LauncherSettings(
    mode: mode ?? this.mode,
    zoneId: zoneId ?? this.zoneId,
    offset: offset ?? this.offset,
    executable: executable ?? this.executable,
    dreamSkinCompatible: dreamSkinCompatible ?? this.dreamSkinCompatible,
  );

  @override
  bool operator ==(Object other) =>
      other is LauncherSettings &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode =>
      Object.hash(mode, zoneId, offset, executable, dreamSkinCompatible);
}

class Zone {
  const Zone(this.id, this.label);
  final String id;
  final String label;
  factory Zone.fromJson(Map<String, dynamic> json) =>
      Zone(json['id'] as String, json['label'] as String);
}
