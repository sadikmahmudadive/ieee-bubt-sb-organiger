import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

import '../../models/chat_thread.dart';
import '../../models/user_profile.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';
import 'user_profile_providers.dart';
import 'call_signaling.dart';

final callThreadProvider = StreamProvider.autoDispose
    .family<ChatThread?, String>((ref, threadId) {
      final db = ref.watch(firestoreProvider);
      return db
          .collection(FirestorePaths.chatThreads)
          .doc(threadId)
          .snapshots()
          .map((d) => d.exists ? ChatThread.fromDoc(d) : null);
    });

class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.threadId, required this.type});

  final String threadId;
  final String type; // "audio" or "video"

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  bool _muted = false;
  bool _speaker = true;
  bool _cameraOn = false;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;
  String _status = 'Connecting...';
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  CallSignaling? _signaling;
  MediaStream? _localStream;
  Future<void> _endCallAndExit() async {
    if (!mounted) return;
    await _signaling?.end();
    if (!mounted) return;
    context.pop();
  }

  @override
  void initState() {
    super.initState();
    _cameraOn = widget.type == 'video';
    _initRenderers();
    unawaited(_startCall());
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _signaling?.end();
    _localRenderer?.dispose();
    _remoteRenderer?.dispose();
    super.dispose();
  }

  Future<void> _initRenderers() async {
    _localRenderer = RTCVideoRenderer();
    _remoteRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    await _remoteRenderer!.initialize();
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsed = Duration.zero;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _elapsed += const Duration(seconds: 1);
        _status = 'On call - ${_formatElapsed(_elapsed)}';
      });
    });
  }

  void _toggleMute() {
    final next = !_muted;
    setState(() => _muted = next);
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !next);
  }

  void _toggleSpeaker() {
    final next = !_speaker;
    setState(() => _speaker = next);
    Helper.setSpeakerphoneOn(next);
  }

  void _toggleCamera() {
    final next = !_cameraOn;
    setState(() => _cameraOn = next);
    _localStream?.getVideoTracks().forEach((t) => t.enabled = next);
  }

  Future<void> _startCall() async {
    final db = ref.read(firestoreProvider);
    final auth = ref.read(firebaseAuthProvider);

    final signaling = CallSignaling(
      threadId: widget.threadId,
      type: widget.type,
      db: db,
      auth: auth,
      onLocalStream: (stream) async {
        _localStream = stream;
        if (_localRenderer != null && mounted) {
          _localRenderer!.srcObject = stream;
          setState(() {});
        }
      },
      onRemoteStream: (stream) async {
        if (_remoteRenderer != null && mounted) {
          _remoteRenderer!.srcObject = stream;
          setState(() {
            _status = 'On call';
          });
        }
      },
      onState: (state) {
        if (!mounted) return;
        switch (state) {
          case CallSessionState.connecting:
            setState(() => _status = 'Connecting...');
            break;
          case CallSessionState.ringing:
            setState(() => _status = 'Ringing...');
            break;
          case CallSessionState.connected:
            setState(() {
              _status = 'On call';
            });
            _startElapsedTimer();
            break;
          case CallSessionState.ended:
            setState(() => _status = 'Call ended');
            break;
          case CallSessionState.error:
            setState(() => _status = 'Call failed');
            break;
        }
      },
    );

    _signaling = signaling;
    await signaling.start();
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final threadAsync = ref.watch(callThreadProvider(widget.threadId));

    return threadAsync.when(
      data: (thread) {
        final otherUid = (thread != null && !thread.isGroup && myUid != null)
            ? thread.memberUids.firstWhere(
                (id) => id != myUid,
                orElse: () =>
                    thread.memberUids.isNotEmpty ? thread.memberUids.first : '',
              )
            : '';

        final profileAsync = otherUid.isNotEmpty
            ? ref.watch(userProfileProvider(otherUid))
            : const AsyncValue<UserProfile?>.data(null);

        return profileAsync.when(
          data: (profile) {
            final displayName = thread == null
                ? 'Call'
                : thread.isGroup
                ? (thread.name ?? 'Group call')
                : (profile?.displayName ?? 'Call');
            final subtitle = widget.type == 'video'
                ? 'Video call'
                : 'Voice call';
            final photoUrl = thread?.photoUrl ?? profile?.photoUrl;

            return Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                children: [
                  if (widget.type == 'video' && _remoteRenderer != null)
                    Positioned.fill(
                      child: RTCVideoView(
                        _remoteRenderer!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    )
                  else
                    _CallBackground(
                      photoUrl: photoUrl,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.arrow_back,
                                  color: Colors.white,
                                ),
                                onPressed: _endCallAndExit,
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      widget.type == 'video'
                                          ? Icons.videocam_outlined
                                          : Icons.call,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Center(
                            child: Column(
                              children: [
                                if (widget.type == 'video' &&
                                    _remoteRenderer == null)
                                  _Avatar(
                                    photoUrl: photoUrl,
                                    name: displayName,
                                    isGroup: thread?.isGroup ?? false,
                                  )
                                else if (widget.type != 'video')
                                  _Avatar(
                                    photoUrl: photoUrl,
                                    name: displayName,
                                    isGroup: thread?.isGroup ?? false,
                                  ),
                                if (widget.type == 'video' &&
                                    _localRenderer != null)
                                  Align(
                                    alignment: Alignment.bottomRight,
                                    child: Container(
                                      width: 120,
                                      height: 160,
                                      margin: const EdgeInsets.only(top: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.4,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: RTCVideoView(
                                          _localRenderer!,
                                          mirror: true,
                                          objectFit: RTCVideoViewObjectFit
                                              .RTCVideoViewObjectFitCover,
                                        ),
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 16),
                                Text(
                                  displayName,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _status,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          _CallControls(
                            type: widget.type,
                            muted: _muted,
                            speaker: _speaker,
                            cameraOn: _cameraOn,
                            onMute: _toggleMute,
                            onSpeaker: _toggleSpeaker,
                            onCamera: _toggleCamera,
                            onEnd: _endCallAndExit,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
          loading: () => const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: Text(
                'Unable to start call',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Call unavailable',
            style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
          ),
        ),
      ),
    );
  }
}

class _CallBackground extends StatelessWidget {
  const _CallBackground({required this.photoUrl, required this.color});

  final String? photoUrl;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.82),
            Colors.black.withValues(alpha: 0.86),
          ],
        ),
      ),
      child: photoUrl == null
          ? const SizedBox.shrink()
          : Stack(
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.35),
                      BlendMode.darken,
                    ),
                    child: Image.network(
                      photoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.photoUrl,
    required this.name,
    required this.isGroup,
  });

  final String? photoUrl;
  final String name;
  final bool isGroup;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 52,
      backgroundColor: Colors.white.withValues(alpha: 0.12),
      backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
      child: photoUrl == null
          ? Icon(
              isGroup ? Icons.groups : Icons.person,
              color: Colors.white,
              size: 38,
            )
          : null,
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({
    required this.type,
    required this.muted,
    required this.speaker,
    required this.cameraOn,
    required this.onMute,
    required this.onSpeaker,
    required this.onCamera,
    required this.onEnd,
  });

  final String type;
  final bool muted;
  final bool speaker;
  final bool cameraOn;
  final VoidCallback onMute;
  final VoidCallback onSpeaker;
  final VoidCallback onCamera;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final showVideoToggle = type == 'video';
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ActionButton(
              icon: muted ? Icons.mic_off : Icons.mic,
              label: muted ? 'Unmute' : 'Mute',
              onTap: onMute,
            ),
            if (showVideoToggle)
              _ActionButton(
                icon: cameraOn ? Icons.videocam : Icons.videocam_off,
                label: cameraOn ? 'Camera' : 'Camera off',
                onTap: onCamera,
              ),
            _ActionButton(
              icon: speaker ? Icons.volume_up : Icons.hearing,
              label: speaker ? 'Speaker' : 'Earpiece',
              onTap: onSpeaker,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: onEnd,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.redAccent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withValues(alpha: 0.4),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.call_end, color: Colors.white, size: 32),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.9),
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
