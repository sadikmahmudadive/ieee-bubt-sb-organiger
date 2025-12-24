import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/user_profile.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

final userProfileProvider = StreamProvider.family<UserProfile?, String>((
  ref,
  uid,
) {
  // Keep profiles warm briefly to avoid re-subscribing while scrolling.
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() {
    timer = Timer(const Duration(minutes: 5), link.close);
  });
  ref.onResume(() {
    timer?.cancel();
    timer = null;
  });
  ref.onDispose(() {
    timer?.cancel();
  });

  final db = ref.watch(firestoreProvider);
  return db.collection(FirestorePaths.users).doc(uid).snapshots().map((d) {
    if (!d.exists) return null;
    return UserProfile.fromDoc(d);
  });
});
