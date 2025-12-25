import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/chat_thread.dart';
import '../../models/user_profile.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';
import 'user_profile_providers.dart';

final chatThreadByIdProvider = StreamProvider.autoDispose
    .family<ChatThread?, String>((ref, threadId) {
      final db = ref.watch(firestoreProvider);
      return db
          .collection(FirestorePaths.chatThreads)
          .doc(threadId)
          .snapshots()
          .map((d) {
            if (!d.exists) return null;
            return ChatThread.fromDoc(d);
          });
    });

class ChatProfileScreen extends ConsumerStatefulWidget {
  const ChatProfileScreen({super.key, required this.threadId});

  final String threadId;

  @override
  ConsumerState<ChatProfileScreen> createState() => _ChatProfileScreenState();
}

class _ChatProfileScreenState extends ConsumerState<ChatProfileScreen> {
  bool _muted = false;

  Future<void> _openGroupProfileSheet(ChatThread thread) async {
    final cs = Theme.of(context).colorScheme;
    final groupName = (thread.name ?? 'Group chat').trim();
    final groupPhotoUrl = (thread.photoUrl ?? '').trim();
    final memberUids = thread.memberUids;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        final height = MediaQuery.sizeOf(ctx).height;

        Future<void> copyThreadId() async {
          await Clipboard.setData(ClipboardData(text: thread.id));
          if (!ctx.mounted) return;
          Navigator.of(ctx).pop();
          if (!mounted) return;
          _toast('Group id copied');
        }

        return SafeArea(
          child: SizedBox(
            height: height * 0.75,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: cs.primaryContainer,
                        backgroundImage: groupPhotoUrl.isNotEmpty
                            ? NetworkImage(groupPhotoUrl)
                            : null,
                        child: groupPhotoUrl.isEmpty
                            ? Icon(Icons.groups, color: cs.onPrimaryContainer)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(ctx).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${memberUids.length} members',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(ctx).textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.copy),
                    title: const Text('Copy group id'),
                    subtitle: Text(
                      thread.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: copyThreadId,
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Text('Members', style: Theme.of(ctx).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, _) {
                        return ListView.separated(
                          itemCount: memberUids.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final uid = memberUids[index];
                            final profileAsync = ref.watch(
                              userProfileProvider(uid),
                            );
                            final cs = Theme.of(context).colorScheme;

                            final name = profileAsync.maybeWhen(
                              data: (p) {
                                final n = (p?.displayName ?? '').trim();
                                return n.isNotEmpty ? n : 'Member';
                              },
                              orElse: () => 'Member',
                            );

                            final photoUrl = profileAsync.maybeWhen(
                              data: (p) => (p?.photoUrl ?? '').trim(),
                              orElse: () => '',
                            );

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                backgroundColor: cs.surfaceContainerHighest,
                                backgroundImage: photoUrl.isNotEmpty
                                    ? NetworkImage(photoUrl)
                                    : null,
                                child: photoUrl.isEmpty
                                    ? Text(
                                        name.isNotEmpty
                                            ? name.characters.first
                                                  .toUpperCase()
                                            : '?',
                                      )
                                    : null,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                uid,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                tooltip: 'Copy user id',
                                icon: const Icon(Icons.copy, size: 18),
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: uid),
                                  );
                                  if (!mounted) return;
                                  _toast('User id copied');
                                },
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openDmProfileSheet(String otherUid) async {
    final cs = Theme.of(context).colorScheme;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, _) {
            final theme = Theme.of(context);
            final profileAsync = ref.watch(userProfileProvider(otherUid));

            Widget avatar = CircleAvatar(
              radius: 28,
              backgroundColor: cs.primaryContainer,
              child: Icon(Icons.person, color: cs.onPrimaryContainer),
            );
            String title = 'Member';
            String subtitle = '';

            profileAsync.whenData((p) {
              final url = (p?.photoUrl ?? '').trim();
              if (url.isNotEmpty) {
                avatar = CircleAvatar(
                  radius: 28,
                  backgroundImage: NetworkImage(url),
                );
              }
              final displayName = (p?.displayName ?? '').trim();
              if (displayName.isNotEmpty) title = displayName;

              if (p?.online == true) {
                subtitle = 'Online';
              } else if (p?.lastSeen != null) {
                final dt = p!.lastSeen!;
                final now = DateTime.now();
                final diff = now.difference(dt);
                final label = diff.inMinutes < 60
                    ? '${diff.inMinutes}m ago'
                    : diff.inHours < 24
                    ? '${diff.inHours}h ago'
                    : DateFormat('MMM d, h:mm a').format(dt);
                subtitle = 'Last seen $label';
              }
            });

            Future<void> copyUid() async {
              await Clipboard.setData(ClipboardData(text: otherUid));
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              _toast('User id copied');
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        avatar,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                              if (subtitle.isNotEmpty)
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.copy),
                      title: const Text('Copy user id'),
                      subtitle: Text(
                        otherUid,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: copyUid,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _startCall(String type) async {
    final cs = Theme.of(context).colorScheme;
    final link = 'https://call.example.com/${widget.threadId}?type=$type';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        var muted = false;
        var camera = type == 'video';
        var speaker = true;

        Future<void> shareLink() async {
          await Clipboard.setData(ClipboardData(text: link));
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Call link copied: $link')));
        }

        Future<void> startCall() async {
          await shareLink();
          if (ctx.mounted) Navigator.of(ctx).pop();
        }

        return StatefulBuilder(
          builder: (context, setState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: cs.primaryContainer,
                      child: Icon(
                        type == 'video' ? Icons.videocam : Icons.call,
                        color: cs.onPrimaryContainer,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      type == 'video'
                          ? 'Start a video call'
                          : 'Start a voice call',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Share the link or jump straight in. Controls stay here while you call.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 14,
                      runSpacing: 10,
                      children: [
                        _CallToggle(
                          icon: muted ? Icons.mic_off : Icons.mic,
                          label: muted ? 'Muted' : 'Mic',
                          active: muted,
                          onTap: () => setState(() => muted = !muted),
                        ),
                        _CallToggle(
                          icon: speaker ? Icons.volume_up : Icons.volume_mute,
                          label: speaker ? 'Speaker' : 'Earpiece',
                          active: speaker,
                          onTap: () => setState(() => speaker = !speaker),
                        ),
                        _CallToggle(
                          icon: camera ? Icons.videocam : Icons.videocam_off,
                          label: camera ? 'Camera' : 'Camera off',
                          active: camera,
                          onTap: () => setState(() => camera = !camera),
                        ),
                        _CallToggle(
                          icon: Icons.message_outlined,
                          label: 'Chat',
                          active: false,
                          onTap: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: Icon(
                          type == 'video' ? Icons.videocam : Icons.call,
                        ),
                        onPressed: startCall,
                        label: Text(
                          type == 'video'
                              ? 'Start video call'
                              : 'Start voice call',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.link),
                        onPressed: shareLink,
                        label: const Text('Copy invite link'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final threadAsync = ref.watch(chatThreadByIdProvider(widget.threadId));
    final user = ref.watch(firebaseAuthProvider).currentUser;
    final myUid = user?.uid;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(backgroundColor: cs.surface, elevation: 0),
      body: threadAsync.when(
        data: (thread) {
          if (thread == null) {
            return const Center(child: Text('Chat not found'));
          }

          final otherUid = (!thread.isGroup && myUid != null)
              ? thread.memberUids.firstWhere(
                  (id) => id != myUid,
                  orElse: () => '',
                )
              : '';

          final AsyncValue<UserProfile?> otherProfileAsync = otherUid.isNotEmpty
              ? ref.watch(userProfileProvider(otherUid))
              : const AsyncValue<UserProfile?>.data(null);

          final title = thread.isGroup
              ? (thread.name ?? 'Group chat')
              : otherProfileAsync.maybeWhen(
                  data: (p) => (p?.displayName.isNotEmpty ?? false)
                      ? p!.displayName
                      : 'Direct message',
                  orElse: () => 'Direct message',
                );

          final groupPhotoUrl = (thread.photoUrl ?? '').trim();

          final avatar = thread.isGroup
              ? (groupPhotoUrl.isNotEmpty ? NetworkImage(groupPhotoUrl) : null)
              : otherProfileAsync.maybeWhen(
                  data: (p) {
                    final url = (p?.photoUrl ?? '').trim();
                    return url.isNotEmpty ? NetworkImage(url) : null;
                  },
                  orElse: () => null,
                );

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const SizedBox(height: 8),
              Center(
                child: CircleAvatar(
                  radius: 48,
                  backgroundColor: cs.primaryContainer,
                  backgroundImage: avatar,
                  child: avatar == null
                      ? Icon(
                          thread.isGroup ? Icons.groups : Icons.person,
                          size: 40,
                          color: cs.onPrimaryContainer,
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Messenger',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionChip(
                    icon: Icons.call,
                    label: 'Audio',
                    onTap: () => _startCall('audio'),
                  ),
                  _ActionChip(
                    icon: Icons.videocam,
                    label: 'Video',
                    onTap: () => _startCall('video'),
                  ),
                  _ActionChip(
                    icon: Icons.person_outline,
                    label: 'Profile',
                    onTap: () {
                      if (thread.isGroup) {
                        unawaited(_openGroupProfileSheet(thread));
                        return;
                      }
                      if (otherUid.isEmpty) {
                        _toast('Profile unavailable');
                        return;
                      }
                      unawaited(_openDmProfileSheet(otherUid));
                    },
                  ),
                  _ActionChip(
                    icon: _muted
                        ? Icons.notifications_off
                        : Icons.notifications,
                    label: 'Mute',
                    onTap: () => setState(() => _muted = !_muted),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Color'),
                trailing: Container(
                  height: 18,
                  width: 18,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                onTap: () => _toast('Color is not implemented yet'),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Emoji'),
                trailing: const Text('👍', style: TextStyle(fontSize: 22)),
                onTap: () => _toast('Emoji is not implemented yet'),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Nicknames'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _toast('Nicknames is not implemented yet'),
              ),
              const SizedBox(height: 10),
              _SectionLabel(text: 'MORE ACTIONS'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Search in Conversation'),
                trailing: Icon(Icons.search, color: cs.onSurfaceVariant),
                onTap: () => _toast('Search is not implemented yet'),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Create group'),
                trailing: Icon(Icons.group, color: cs.onSurfaceVariant),
                onTap: () => context.push('/chats/create-group'),
              ),
              const SizedBox(height: 10),
              _SectionLabel(text: 'PRIVACY'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Notifications'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _muted ? 'Off' : 'On',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => setState(() => _muted = !_muted),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ignore Messages'),
                trailing: Icon(
                  Icons.do_not_disturb_on_outlined,
                  color: cs.onSurfaceVariant,
                ),
                onTap: () => _toast('Ignore Messages is not implemented yet'),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Block'),
                trailing: Icon(Icons.block, color: cs.onSurfaceVariant),
                onTap: () => _toast('Block is not implemented yet'),
              ),
              const SizedBox(height: 10),
              Text(
                DateFormat('MMM d, y').format(DateTime.now()),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(e.toString())),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 34,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: cs.surfaceContainerHighest,
            child: Icon(icon, color: cs.onSurface),
          ),
          const SizedBox(height: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _CallToggle extends StatelessWidget {
  const _CallToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? cs.primary : cs.outlineVariant,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
