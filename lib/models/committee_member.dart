import 'package:cloud_firestore/cloud_firestore.dart';

class CommitteeMember {
  const CommitteeMember({
    required this.id,
    required this.name,
    required this.role,
    this.email,
    this.photoUrl,
    this.order,
  });

  final String id;
  final String name;
  final String role;
  final String? email;
  final String? photoUrl;
  final int? order;

  factory CommitteeMember.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return CommitteeMember(
      id: doc.id,
      name: (data['name'] ?? '').toString(),
      role: (data['role'] ?? '').toString(),
      email: (data['email'] as String?),
      photoUrl: (data['photoUrl'] as String?),
      order: (data['order'] as int?),
    );
  }
}
