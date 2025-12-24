import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/chat_thread.dart';
import '../../models/user_profile.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';
import 'chat_thread_screen.dart';
import 'user_profile_providers.dart';

final myThreadsProvider = StreamProvider.autoDispose<List<ChatThread>>((ref) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() {
    timer = Timer(const Duration(minutes: 3), link.close);
  });
  ref.onResume(() {
    timer?.cancel();
    timer = null;
  });
  ref.onDispose(() {
    timer?.cancel();
  });

  final user = ref.watch(firebaseAuthProvider).currentUser;
  if (user == null) return const Stream.empty();

  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.chatThreads)
      .where('memberUids', arrayContains: user.uid)
      .orderBy('lastMessageAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(ChatThread.fromDoc).toList());
});

final peopleProvider = StreamProvider.autoDispose<List<UserProfile>>((ref) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() {
    timer = Timer(const Duration(minutes: 3), link.close);
  });
  ref.onResume(() {
    timer?.cancel();
    timer = null;
  });
  ref.onDispose(() {
    timer?.cancel();
  });

  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.users)
      .orderBy('displayName')
      .limit(100)
      .snapshots()
      .map((s) => s.docs.map(UserProfile.fromDoc).toList());
});

Future<void> _startDirectMessage(
  BuildContext context,
  WidgetRef ref,
  UserProfile profile,
) async {
  final auth = ref.read(firebaseAuthProvider);
  final myUid = auth.currentUser?.uid;
  if (myUid == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Sign in to message people.')));
    return;
  }

  final db = ref.read(firestoreProvider);
  final existing = await db
      .collection(FirestorePaths.chatThreads)
      .where('isGroup', isEqualTo: false)
      .where('memberUids', arrayContains: myUid)
      .limit(40)
      .get();

  String? threadId;
  for (final doc in existing.docs) {
    final members =
        (doc.data()['memberUids'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];
    if (members.contains(profile.uid)) {
      threadId = doc.id;
      break;
    }
  }

  threadId ??= (await db.collection(FirestorePaths.chatThreads).add({
    'isGroup': false,
    'memberUids': [myUid, profile.uid],
    'createdBy': myUid,
    'createdAt': FieldValue.serverTimestamp(),
    'lastMessageAt': FieldValue.serverTimestamp(),
    'lastMessageText': '',
  })).id;

  if (!context.mounted) return;
  context.push('/chats/thread/$threadId');
}

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  String? _selectedThreadId;

  static const double _splitViewMinWidth = 900;
  static const double _splitViewListWidth = 380;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(firebaseAuthProvider);
    final myUid = auth.currentUser?.uid;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final splitView = constraints.maxWidth >= _splitViewMinWidth;

        if (splitView) {
          final threadsAsync = ref.watch(myThreadsProvider);
          threadsAsync.whenData((threads) {
            if (_selectedThreadId == null && threads.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() => _selectedThreadId = threads.first.id);
              });
            }
          });
        }

        return DefaultTabController(
          length: 2,
          child: Builder(
            builder: (context) {
              // ignore: unnecessary_non_null_assertion
              final tabController = DefaultTabController.of(context)!;
              return AnimatedBuilder(
                animation: tabController,
                builder: (context, _) {
                  return Scaffold(
                    backgroundColor: cs.surface,
                    appBar: AppBar(
                      elevation: 0,
                      centerTitle: false,
                      title: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Messages', style: theme.textTheme.titleLarge),
                          if (myUid != null)
                            Text(
                              'Stay connected with your groups',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      actions: [
                        if (myUid != null)
                          IconButton(
                            tooltip: 'New group chat',
                            onPressed: () =>
                                context.push('/chats/create-group'),
                            icon: const Icon(Icons.edit_square),
                          ),
                      ],
                      bottom: const TabBar(
                        tabs: [
                          Tab(text: 'Chats'),
                          Tab(text: 'People'),
                        ],
                      ),
                    ),
                    body: TabBarView(
                      children: [
                        splitView
                            ? _SplitChatsTab(
                                selectedThreadId: _selectedThreadId,
                                onSelect: (id) =>
                                    setState(() => _selectedThreadId = id),
                              )
                            : const _ChatsTab(),
                        splitView
                            ? const _SplitPeopleTab()
                            : const _PeopleTab(),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _SplitChatsTab extends ConsumerWidget {
  const _SplitChatsTab({
    required this.selectedThreadId,
    required this.onSelect,
  });

  final String? selectedThreadId;
  final ValueChanged<String> onSelect;

  static const double _listWidth = _ChatsScreenState._splitViewListWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadsAsync = ref.watch(myThreadsProvider);
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final cs = Theme.of(context).colorScheme;

    return threadsAsync.when(
      data: (threads) {
        return Row(
          children: [
            SizedBox(
              width: _listWidth,
              child: ColoredBox(
                color: cs.surface,
                child: threads.isEmpty
                    ? _EmptyChats(
                        signedIn: myUid != null,
                        onCreate: () => context.push('/chats/create-group'),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                        itemCount: threads.length,
                        separatorBuilder: (context, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final t = threads[i];
                          return _ThreadTile(
                            thread: t,
                            myUid: myUid,
                            selected: t.id == selectedThreadId,
                            onTap: () => onSelect(t.id),
                          );
                        },
                      ),
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: selectedThreadId == null
                  ? Center(
                      child: Text(
                        'Select a chat',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    )
                  : ChatThreadScreen(
                      threadId: selectedThreadId!,
                      embedded: true,
                    ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorChats(message: e.toString()),
    );
  }
}

class _ChatsTab extends ConsumerWidget {
  const _ChatsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadsAsync = ref.watch(myThreadsProvider);
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;

    return threadsAsync.when(
      data: (threads) {
        if (threads.isEmpty) {
          return _EmptyChats(
            signedIn: myUid != null,
            onCreate: () => context.push('/chats/create-group'),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
          itemCount: threads.length,
          separatorBuilder: (context, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final t = threads[i];
            return _ThreadTile(
              thread: t,
              myUid: myUid,
              onTap: () => context.push('/chats/thread/${t.id}'),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorChats(message: e.toString()),
    );
  }
}

class _PeopleTab extends ConsumerStatefulWidget {
  const _PeopleTab();

  @override
  ConsumerState<_PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends ConsumerState<_PeopleTab> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peopleAsync = ref.watch(peopleProvider);
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final query = _search.text.trim().toLowerCase();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search people by name or email',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: peopleAsync.when(
            data: (people) {
              final filtered = people.where((p) => p.uid != myUid).where((p) {
                if (query.isEmpty) return true;
                final name = p.displayName.toLowerCase();
                final email = p.email.toLowerCase();
                return name.contains(query) || email.contains(query);
              }).toList();

              if (filtered.isEmpty) {
                return const Center(child: Text('No people found.'));
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                itemCount: filtered.length,
                separatorBuilder: (context, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final profile = filtered[i];
                  return _PersonTile(
                    profile: profile,
                    onMessage: () => _startDirectMessage(context, ref, profile),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(e.toString())),
          ),
        ),
      ],
    );
  }
}

class _SplitPeopleTab extends ConsumerStatefulWidget {
  const _SplitPeopleTab();

  @override
  ConsumerState<_SplitPeopleTab> createState() => _SplitPeopleTabState();
}

class _SplitPeopleTabState extends ConsumerState<_SplitPeopleTab> {
  final _search = TextEditingController();
  String? _selectedUid;

  static const double _listWidth = _ChatsScreenState._splitViewListWidth;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _statusLabel(UserProfile p) {
    if (p.online == true) return 'Online now';
    if (p.lastSeen != null) {
      final dt = p.lastSeen!;
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return DateFormat('MMM d, h:mm a').format(dt);
    }
    return 'Offline';
  }

  @override
  Widget build(BuildContext context) {
    final peopleAsync = ref.watch(peopleProvider);
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();

    return peopleAsync.when(
      data: (people) {
        final filtered = people.where((p) => p.uid != myUid).where((p) {
          if (query.isEmpty) return true;
          final name = p.displayName.toLowerCase();
          final email = p.email.toLowerCase();
          return name.contains(query) || email.contains(query);
        }).toList();

        if (_selectedUid == null && filtered.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _selectedUid = filtered.first.uid);
          });
        }

        final selected = _selectedUid == null
            ? null
            : filtered
                  .where((p) => p.uid == _selectedUid)
                  .cast<UserProfile?>()
                  .firstOrNull;

        return Row(
          children: [
            SizedBox(
              width: _listWidth,
              child: ColoredBox(
                color: cs.surface,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search people by name or email',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('No people found.'))
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                              itemCount: filtered.length,
                              separatorBuilder: (context, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) {
                                final p = filtered[i];
                                final selectedItem = p.uid == _selectedUid;
                                return Card(
                                  elevation: 0,
                                  color: selectedItem
                                      ? cs.secondaryContainer
                                      : cs.surfaceContainerHighest,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () =>
                                        setState(() => _selectedUid = p.uid),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 22,
                                            backgroundImage:
                                                (p.photoUrl == null ||
                                                    p.photoUrl!.isEmpty)
                                                ? null
                                                : NetworkImage(p.photoUrl!),
                                            child:
                                                (p.photoUrl == null ||
                                                    p.photoUrl!.isEmpty)
                                                ? const Icon(Icons.person)
                                                : null,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  p.displayName.isNotEmpty
                                                      ? p.displayName
                                                      : p.email,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .titleMedium,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  _statusLabel(p),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .labelMedium
                                                      ?.copyWith(
                                                        color:
                                                            cs.onSurfaceVariant,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: selected == null
                  ? Center(
                      child: Text(
                        'Select a person',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    )
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 42,
                                backgroundImage:
                                    (selected.photoUrl == null ||
                                        selected.photoUrl!.isEmpty)
                                    ? null
                                    : NetworkImage(selected.photoUrl!),
                                child:
                                    (selected.photoUrl == null ||
                                        selected.photoUrl!.isEmpty)
                                    ? const Icon(Icons.person, size: 40)
                                    : null,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                selected.displayName.isNotEmpty
                                    ? selected.displayName
                                    : selected.email,
                                style: theme.textTheme.titleLarge,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                selected.email,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _statusLabel(selected),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.tonalIcon(
                                  onPressed: () => _startDirectMessage(
                                    context,
                                    ref,
                                    selected,
                                  ),
                                  icon: const Icon(Icons.chat_bubble_outline),
                                  label: const Text('Message'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(e.toString())),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.profile, required this.onMessage});

  final UserProfile profile;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final online = profile.online == true;
    final subtitle = _statusLabel(profile);

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundImage:
                  (profile.photoUrl == null || profile.photoUrl!.isEmpty)
                  ? null
                  : NetworkImage(profile.photoUrl!),
              child: (profile.photoUrl == null || profile.photoUrl!.isEmpty)
                  ? const Icon(Icons.person)
                  : null,
            ),
            if (online)
              Positioned(
                bottom: -2,
                right: -2,
                child: Container(
                  height: 12,
                  width: 12,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: cs.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          profile.displayName.isNotEmpty ? profile.displayName : profile.email,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        trailing: FilledButton.tonalIcon(
          onPressed: onMessage,
          icon: const Icon(Icons.chat_bubble_outline),
          label: const Text('Message'),
        ),
      ),
    );
  }

  String _statusLabel(UserProfile p) {
    if (p.online == true) return 'Online now';
    if (p.lastSeen != null) {
      final dt = p.lastSeen!;
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return DateFormat('MMM d, h:mm a').format(dt);
    }
    return 'Offline';
  }
}

class _ThreadTile extends ConsumerWidget {
  const _ThreadTile({
    required this.thread,
    required this.myUid,
    required this.onTap,
    this.selected = false,
  });

  final ChatThread thread;
  final String? myUid;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final otherUid = (!thread.isGroup && myUid != null)
        ? thread.memberUids.firstWhere((id) => id != myUid, orElse: () => '')
        : '';
    final AsyncValue<UserProfile?> profileAsync = otherUid.isNotEmpty
        ? ref.watch(userProfileProvider(otherUid))
        : const AsyncValue<UserProfile?>.data(null);

    final lastAt = thread.lastMessageAt;
    final timeLabel = _timeLabel(lastAt);
    final subtitle =
        thread.lastMessageText ??
        (thread.isGroup ? 'Say hi to the group' : 'Start a conversation');

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: selected ? cs.secondaryContainer : cs.surfaceContainerHighest,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _Avatar(thread: thread, profileAsync: profileAsync),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _displayName(thread, profileAsync),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (timeLabel.isNotEmpty)
                          Text(
                            timeLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    if (thread.eventId != null) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Event group',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _displayName(ChatThread t, AsyncValue<UserProfile?> profileAsync) {
    if (t.isGroup) return t.name ?? 'Group chat';
    return profileAsync.when(
      data: (p) =>
          p?.displayName.isNotEmpty == true ? p!.displayName : 'Direct message',
      loading: () => 'Loading...',
      error: (error, stackTrace) => 'Direct message',
    );
  }

  String _timeLabel(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes.clamp(0, 59).toInt()}m';
    }
    if (diff.inHours < 24) {
      return DateFormat('h:mm a').format(dt);
    }
    if (diff.inDays < 7) {
      return DateFormat('EEE').format(dt);
    }
    return DateFormat('MMM d').format(dt);
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.thread, required this.profileAsync});

  final ChatThread thread;
  final AsyncValue<UserProfile?> profileAsync;

  @override
  Widget build(BuildContext context) {
    if (thread.isGroup) {
      final url = thread.photoUrl;
      return CircleAvatar(
        radius: 22,
        backgroundImage: (url == null || url.isEmpty)
            ? null
            : NetworkImage(url),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: (url == null || url.isEmpty)
            ? const Icon(Icons.groups, size: 22)
            : null,
      );
    }

    return profileAsync.when(
      data: (p) {
        final url = p?.photoUrl;
        return CircleAvatar(
          radius: 22,
          backgroundImage: (url == null || url.isEmpty)
              ? null
              : NetworkImage(url),
          child: (url == null || url.isEmpty) ? const Icon(Icons.person) : null,
        );
      },
      loading: () => CircleAvatar(
        radius: 22,
        child: SizedBox(
          height: 16,
          width: 16,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (error, stackTrace) =>
          const CircleAvatar(radius: 22, child: Icon(Icons.person)),
    );
  }
}

class _EmptyChats extends StatelessWidget {
  const _EmptyChats({required this.signedIn, required this.onCreate});

  final bool signedIn;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Chats', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          signedIn
              ? 'No chats yet. Create a group for event management.'
              : 'Sign in to create and join chats.',
        ),
        if (signedIn) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.group_add),
              label: const Text('Create a group'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ErrorChats extends StatelessWidget {
  const _ErrorChats({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Chats', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Could not load chats.'),
        const SizedBox(height: 8),
        SelectableText(message),
      ],
    );
  }
}
