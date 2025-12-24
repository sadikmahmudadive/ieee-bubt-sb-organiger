import 'package:cloud_firestore/cloud_firestore.dart';

class PhotoPost {
  const PhotoPost({
    required this.id,
    required this.imageUrl,
    this.caption,
    this.uploadedBy,
    this.uploadedAt,
  });

  final String id;
  final String imageUrl;
  final String? caption;
  final String? uploadedBy;
  final DateTime? uploadedAt;

  factory PhotoPost.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final ts = data['uploadedAt'] as Timestamp?;

    return PhotoPost(
      id: doc.id,
      imageUrl: (data['imageUrl'] ?? '').toString(),
      caption: (data['caption'] as String?),
      uploadedBy: (data['uploadedBy'] as String?),
      uploadedAt: ts?.toDate(),
    );
  }
}
