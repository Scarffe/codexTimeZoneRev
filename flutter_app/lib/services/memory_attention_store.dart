import 'dart:io';

import 'session_attention.dart';
import 'session_attention_store.dart';

/// Preview and offline trials never read or write portable user state.
class MemoryAttentionStore extends SessionAttentionStore {
  MemoryAttentionStore() : super(File('unused-memory-attention'));
  SessionAttentionSnapshot? _snapshot;
  @override
  Future<SessionAttentionSnapshot?> read() async => _snapshot;
  @override
  Future<void> write(SessionAttentionSnapshot snapshot) async {
    _snapshot = SessionAttentionSnapshot.fromJson(snapshot.toJson());
  }

  @override
  Future<void> flush() async {}
}
