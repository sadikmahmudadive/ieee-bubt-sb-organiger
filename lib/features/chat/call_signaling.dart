import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import '../../services/firestore_paths.dart';
import '../../services/notification_service.dart';

enum CallSessionState { connecting, ringing, connected, ended, error }

class CallSignaling {
  CallSignaling({
    required this.threadId,
    required this.type,
    required this.db,
    required this.auth,
    this.onLocalStream,
    this.onRemoteStream,
    this.onState,
  });

  final String threadId;
  final String type; // audio | video
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final FutureOr<void> Function(MediaStream stream)? onLocalStream;
  final FutureOr<void> Function(MediaStream stream)? onRemoteStream;
  final void Function(CallSessionState state)? onState;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidatesSub;
  DocumentReference<Map<String, dynamic>>? _sessionRef;
  bool _isInitiator = false;
  bool _ended = false;
  bool _isRinging = false;
  bool _hasAnswered = false;

  Future<void> _startRingtone({required bool incoming}) async {
    if (_isRinging) return;
    _isRinging = true;
    await FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.glass,
      looping: true,
      volume: 1.0,
      asAlarm: incoming,
    );
  }

  Future<void> _stopRingtone() async {
    if (!_isRinging) return;
    _isRinging = false;
    await FlutterRingtonePlayer().stop();
  }

  Future<void> _clearSessionIfStale(
    DocumentSnapshot<Map<String, dynamic>> existing,
    String uid,
  ) async {
    final data = existing.data();
    if (data == null) return;

    final createdBy = data['createdBy'] as String?;
    final answer = data['answer'];
    final state = data['state'] as String?;

    // Clear stale session docs so a new call can start even if a previous
    // caller (or someone else) left the session in an "ended" state.
    final shouldClearEnded = state == 'ended';
    final shouldClearOwn =
        createdBy == uid && (answer == null || state == 'ended');
    if (!(shouldClearEnded || shouldClearOwn)) return;

    final candidates = await _sessionRef!.collection('candidates').get();
    for (final doc in candidates.docs) {
      await doc.reference.delete();
    }
    await _sessionRef!.delete();
  }

  Future<void> _ensurePeerConnection() async {
    final isClosed =
        _pc?.signalingState == RTCSignalingState.RTCSignalingStateClosed ||
        _pc?.connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateClosed;
    if (_ended) return;
    if (_pc != null && !isClosed) return;

    await _pc?.close();
    _pc = await createPeerConnection(_config);
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
    }

    _pc!.onTrack = (event) async {
      if (event.streams.isNotEmpty) {
        await onRemoteStream?.call(event.streams.first);
      }
    };

    _pc!.onIceCandidate = (candidate) async {
      if (_sessionRef == null) return;
      await _sessionRef!.collection('candidates').add({
        'from': auth.currentUser?.uid,
        'candidate': candidate.toMap(),
      });
    };

    _pc!.onConnectionState = (state) async {
      if (_ended) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          await _stopRingtone();
          onState?.call(CallSessionState.connected);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          await _stopRingtone();
          onState?.call(CallSessionState.error);
          await end(remoteEnded: false);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          // Allow transient states without tearing down immediately.
          break;
      }
    };
  }

  static const _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  Future<void> start() async {
    final uid = auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('No signed-in user');
    }

    onState?.call(CallSessionState.connecting);

    final constraints = {
      'audio': true,
      'video': type == 'video'
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    await onLocalStream?.call(_localStream!);

    await _ensurePeerConnection();

    _sessionRef = db.collection(FirestorePaths.callSessions).doc(threadId);

    final existing = await _sessionRef!.get();
    await _clearSessionIfStale(existing, uid);

    _sessionSub = _sessionRef!.snapshots().listen(_handleSessionSnapshot);
    final session = await _sessionRef!.get();
    if (!session.exists) {
      _isInitiator = true;
      await _createOffer(uid);
    } else {
      final data = session.data();
      final offer = data?['offer'] as Map<String, dynamic>?;
      if (offer != null) {
        await _acceptOffer(uid, offer, createdBy: data?['createdBy']);
      }
    }

    _candidatesSub = _sessionRef!
        .collection('candidates')
        .snapshots()
        .listen(_handleCandidateSnapshot);
  }

  Future<void> _handleSessionSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) async {
    if (_ended || _pc == null) return;
    final data = snapshot.data();
    if (data == null) return;
    final uid = auth.currentUser?.uid;
    if (uid == null) return;

    final offer = data['offer'] as Map<String, dynamic>?;
    final answer = data['answer'] as Map<String, dynamic>?;
    final state = data['state'] as String?;

    if (state == 'ended') {
      await _stopRingtone();
      await end(remoteEnded: true);
      return;
    }

    final hasRemote = await _pc!.getRemoteDescription() != null;

    if (!_isInitiator && offer != null && !hasRemote) {
      await _startRingtone(incoming: true);
      await NotificationService.instance.showCallAlert(
        title: type == 'video' ? 'Incoming video call' : 'Incoming voice call',
        body: 'Tap to join the call',
      );
      await _acceptOffer(uid, offer, createdBy: data['createdBy'] as String?);
      return;
    }

    if (_isInitiator && answer != null && !hasRemote) {
      await _ensurePeerConnection();
      final desc = RTCSessionDescription(
        answer['sdp'] as String,
        answer['type'] as String,
      );
      try {
        await _pc!.setRemoteDescription(desc);
      } catch (_) {
        await _stopRingtone();
        onState?.call(CallSessionState.error);
        return;
      }
      await _stopRingtone();
      onState?.call(CallSessionState.connected);
    }
  }

  Future<void> _handleCandidateSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) async {
    if (_ended || _pc == null) return;
    final uid = auth.currentUser?.uid;
    if (uid == null) return;

    for (final doc in snapshot.docChanges) {
      final data = doc.doc.data();
      if (data == null) continue;
      if (data['from'] == uid) continue;
      final cand = data['candidate'] as Map<String, dynamic>?;
      if (cand == null) continue;
      await _ensurePeerConnection();
      final ice = RTCIceCandidate(
        cand['candidate'] as String?,
        cand['sdpMid'] as String?,
        cand['sdpMlineIndex'] as int?,
      );
      await _pc!.addCandidate(ice);
    }
  }

  Future<void> _createOffer(String uid) async {
    if (_ended || _localStream == null) return;
    await _ensurePeerConnection();

    // Fetch thread members so we can target call alerts to participants.
    final threadSnap = await db
        .collection(FirestorePaths.chatThreads)
        .doc(threadId)
        .get();
    final memberUids =
        (threadSnap.data()?['memberUids'] as List<dynamic>? ?? <dynamic>[])
            .whereType<String>()
            .toList();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await _sessionRef!.set({
      'threadId': threadId,
      'type': type,
      'state': 'offering',
      'createdBy': uid,
      'participants': [uid],
      'targetUids': memberUids,
      'offer': offer.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await _startRingtone(incoming: false);
    onState?.call(CallSessionState.ringing);
  }

  Future<void> _acceptOffer(
    String uid,
    Map<String, dynamic> offer, {
    String? createdBy,
  }) async {
    if (_hasAnswered) return;
    final state = _pc?.signalingState;
    if (state == RTCSignalingState.RTCSignalingStateStable) return;

    await _ensurePeerConnection();
    await _startRingtone(incoming: true);
    final remote = RTCSessionDescription(
      offer['sdp'] as String,
      offer['type'] as String,
    );
    try {
      await _pc!.setRemoteDescription(remote);
    } catch (_) {
      onState?.call(CallSessionState.error);
      return;
    }
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    _hasAnswered = true;
    await _sessionRef!.set({
      'threadId': threadId,
      'type': type,
      'state': 'connected',
      'createdBy': createdBy ?? uid,
      'participants': FieldValue.arrayUnion([uid]),
      'targetUids': FieldValue.arrayUnion([uid]),
      'offer': offer,
      'answer': answer.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _stopRingtone();
    onState?.call(CallSessionState.connected);
  }

  Future<void> end({bool remoteEnded = false}) async {
    if (_ended) return;
    _ended = true;
    onState?.call(CallSessionState.ended);
    await _stopRingtone();
    await _sessionSub?.cancel();
    await _candidatesSub?.cancel();
    await _pc?.close();
    await _localStream?.dispose();
    if (!remoteEnded && _sessionRef != null) {
      await _sessionRef!.set({'state': 'ended'}, SetOptions(merge: true));
    }
  }
}
