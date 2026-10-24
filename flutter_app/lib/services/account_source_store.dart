import 'dart:convert';
import 'dart:io';

/// Noncredential catalog. A corrupt read locks writes for this store lifetime.
class AccountSourceStore {
  AccountSourceStore(this.file);
  AccountSourceStore.memory() : file = null;
  factory AccountSourceStore.portable() => AccountSourceStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/account-sources-v1.json',
    ),
  );
  final File? file;
  bool _locked = false;
  Future<void> _pending = Future<void>.value();
  Map<String, dynamic> _memory = {};
  void protectCorruptCatalog() {
    _locked = true;
  }

  Future<Map<String, dynamic>> read() async {
    await _pending;
    final disk = file;
    if (disk == null) {
      return jsonDecode(jsonEncode(_memory)) as Map<String, dynamic>;
    }
    if (!await disk.exists()) return {};
    try {
      final value = jsonDecode(await disk.readAsString());
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['sources'] is! List) {
        throw const FormatException('Invalid source catalog');
      }
      return value;
    } catch (_) {
      _locked = true;
      rethrow;
    }
  }

  Future<void> write(Map<String, Object?> value) {
    // Freeze before enqueueing so later mutations cannot alter this revision.
    final encoded = jsonEncode({'version': 1, ...value});
    final operation = _pending.then((_) async {
      if (_locked) {
        throw StateError('Source catalog is locked after a corrupt read');
      }
      final disk = file;
      if (disk == null) {
        _memory = jsonDecode(encoded) as Map<String, dynamic>;
        return;
      }
      final temporary = File('${disk.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(disk.path);
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
