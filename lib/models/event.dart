import 'package:cloud_firestore/cloud_firestore.dart';

class Event {
  const Event({
    required this.id,
    required this.title,
    required this.startAt,
    this.description,
    this.location,
    this.endAt,
    this.createdBy,
  });

  final String id;
  final String title;
  final String? description;
  final String? location;
  final DateTime startAt;
  final DateTime? endAt;
  final String? createdBy;

  factory Event.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final startTs = data['startAt'] as Timestamp?;
    final endTs = data['endAt'] as Timestamp?;

    return Event(
      id: doc.id,
      title: (data['title'] ?? '').toString(),
      description: (data['description'] as String?),
      location: (data['location'] as String?),
      startAt: (startTs?.toDate()) ?? DateTime.fromMillisecondsSinceEpoch(0),
      endAt: endTs?.toDate(),
      createdBy: (data['createdBy'] as String?),
    );
  }

  Map<String, dynamic> toCreateMap() {
    return {
      'title': title,
      'description': description,
      'location': location,
      'startAt': Timestamp.fromDate(startAt),
      'endAt': endAt == null ? null : Timestamp.fromDate(endAt!),
      'createdBy': createdBy,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }
}
