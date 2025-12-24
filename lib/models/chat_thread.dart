import 'package:cloud_firestore/cloud_firestore.dart';

class ChatThread {
  const ChatThread({
    required this.id,
    required this.isGroup,
    required this.memberUids,
    this.name,
    this.photoUrl,
    this.eventId,
    this.lastMessageText,
    this.lastMessageAt,
    this.memberReads,
    this.typing,
  });

  final String id;
  final bool isGroup;
  final List<String> memberUids;
  final String? name;
  final String? photoUrl;
  final String? eventId;
  final String? lastMessageText;
  final DateTime? lastMessageAt;
  final Map<String, DateTime>? memberReads;
  final Map<String, bool>? typing;

  factory ChatThread.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final members =
        (data['memberUids'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final lastAt = data['lastMessageAt'] as Timestamp?;
    final readsRaw = data['memberReads'] as Map<String, dynamic>?;
    final typingRaw = data['typing'] as Map<String, dynamic>?;

    final reads = <String, DateTime>{};
    if (readsRaw != null) {
      for (final entry in readsRaw.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is Timestamp) {
          reads[key] = value.toDate();
        } else if (value is DateTime) {
          reads[key] = value;
        }
      }
    }

    return ChatThread(
      id: doc.id,
      isGroup: (data['isGroup'] as bool?) ?? false,
      memberUids: members,
      name: (data['name'] as String?),
      photoUrl: (data['photoUrl'] as String?),
      eventId: (data['eventId'] as String?),
      lastMessageText: (data['lastMessageText'] as String?),
      lastMessageAt: lastAt?.toDate(),
      memberReads: reads.isEmpty ? null : reads,
      typing: typingRaw?.map((k, v) => MapEntry(k, v == true)),
    );
  }
}
