import 'package:cloud_firestore/cloud_firestore.dart';

class UserProfile {
  const UserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    this.photoUrl,
    this.lastSeen,
    this.online,
  });

  final String uid;
  final String email;
  final String displayName;
  final String? photoUrl;
  final DateTime? lastSeen;
  final bool? online;

  factory UserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final ls = data['lastSeen'] as Timestamp?;
    return UserProfile(
      uid: doc.id,
      email: (data['email'] ?? '').toString(),
      displayName: (data['displayName'] ?? '').toString(),
      photoUrl: (data['photoUrl'] as String?),
      lastSeen: ls?.toDate(),
      online: data['online'] as bool?,
    );
  }
}
