import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../services/firestore_paths.dart';
import '../../services/notification_service.dart';

/// Listens for call session offers targeting the current user and surfaces
/// local call notifications even when the call screen is not open.
final incomingCallListenerProvider = Provider.autoDispose<void>((ref) {
  final authState = ref.watch(authStateProvider);
  final db = ref.watch(firestoreProvider);
  final uid = authState.value?.uid;
  if (uid == null) return;

  final notified = <String>{};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? sub;
  sub = db
      .collection(FirestorePaths.callSessions)
      .where('targetUids', arrayContains: uid)
      .where('state', isEqualTo: 'offering')
      .snapshots()
      .listen((snapshot) async {
        for (final change in snapshot.docChanges) {
          final data = change.doc.data();
          if (data == null) continue;

          final createdBy = data['createdBy'] as String?;
          final state = data['state'] as String?;
          final offer = data['offer'];

          final isEnded = state == 'ended';
          if (isEnded || offer == null) continue;
          if (createdBy == uid) continue;

          if (notified.contains(change.doc.id)) continue;
          notified.add(change.doc.id);

          final type = data['type'] as String?;
          final title = type == 'video'
              ? 'Incoming video call'
              : 'Incoming voice call';

          await NotificationService.instance.showCallAlert(
            title: title,
            body: 'Tap to join the call',
          );
        }
      });

  ref.onDispose(() async {
    await sub?.cancel();
  });
});
