import 'package:cloud_firestore/cloud_firestore.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderUid,
    required this.text,
    this.imageUrl,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.audioUrl,
    this.audioDurationSec,
    this.replyToMessageId,
    this.replyToText,
    this.replyToSenderUid,
    this.sentAt,
    this.pending = false,
    this.reactions,
    this.deleted = false,
    this.edited = false,
  });

  final String id;
  final String senderUid;
  final String text;
  final String? imageUrl;
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? audioUrl;
  final int? audioDurationSec;
  final String? replyToMessageId;
  final String? replyToText;
  final String? replyToSenderUid;
  final DateTime? sentAt;
  final bool pending;
  final Map<String, String>? reactions;
  final bool deleted;
  final bool edited;

  factory ChatMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final sentTs = data['sentAt'] as Timestamp?;
    final reactionsRaw = data['reactions'] as Map<String, dynamic>?;

    return ChatMessage(
      id: doc.id,
      senderUid: (data['senderUid'] ?? '').toString(),
      text: (data['text'] ?? '').toString(),
      imageUrl: (data['imageUrl'] as String?),
      fileUrl: (data['fileUrl'] as String?),
      fileName: (data['fileName'] as String?),
      fileSize: (data['fileSize'] as num?)?.toInt(),
      audioUrl: (data['audioUrl'] as String?),
      audioDurationSec: (data['audioDurationSec'] as num?)?.toInt(),
      replyToMessageId: (data['replyToMessageId'] as String?),
      replyToText: (data['replyToText'] as String?),
      replyToSenderUid: (data['replyToSenderUid'] as String?),
      sentAt: sentTs?.toDate(),
      pending: doc.metadata.hasPendingWrites,
      reactions: reactionsRaw?.map((k, v) => MapEntry(k, (v ?? '').toString())),
      deleted: data['deleted'] == true,
      edited: data['edited'] == true,
    );
  }
}
