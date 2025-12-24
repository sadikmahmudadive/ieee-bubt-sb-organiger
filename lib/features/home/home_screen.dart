import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/event.dart';
import '../../models/photo_post.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

final upcomingEventsPreviewProvider = StreamProvider<List<Event>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.events)
      .orderBy('startAt', descending: false)
      .limit(3)
      .snapshots()
      .map((s) => s.docs.map(Event.fromDoc).toList());
});

final recentPhotosPreviewProvider = StreamProvider<List<PhotoPost>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.photoPosts)
      .orderBy('uploadedAt', descending: true)
      .limit(4)
      .snapshots()
      .map((s) => s.docs.map(PhotoPost.fromDoc).toList());
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventsPreview = ref.watch(upcomingEventsPreviewProvider);
    final photosPreview = ref.watch(recentPhotosPreviewProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'IEEE BUBT Student Branch',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          'Committee • Events • Event chats • Photo corner',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _QuickActionCard(
                icon: Icons.groups,
                title: 'Committee',
                subtitle: 'Members & roles',
                onTap: () => context.go('/committees'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickActionCard(
                icon: Icons.event,
                title: 'Events',
                subtitle: 'Upcoming & reminders',
                onTap: () => context.go('/events'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _QuickActionCard(
                icon: Icons.chat_bubble,
                title: 'Chats',
                subtitle: 'Event management',
                onTap: () => context.go('/chats'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickActionCard(
                icon: Icons.photo_library,
                title: 'Photo corner',
                subtitle: 'Share memories',
                onTap: () => context.go('/photos'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SectionHeader(
          title: 'Upcoming events',
          action: TextButton(
            onPressed: () => context.go('/events'),
            child: const Text('See all'),
          ),
        ),
        eventsPreview.when(
          data: (events) {
            if (events.isEmpty) return const Text('No events yet.');
            return Column(
              children: [
                for (final e in events)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.event_outlined),
                      title: Text(e.title),
                      subtitle: Text(e.startAt.toLocal().toString()),
                      onTap: () => context.push('/events/${e.id}'),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text(e.toString()),
        ),
        const SizedBox(height: 16),
        _SectionHeader(
          title: 'Latest photos',
          action: TextButton(
            onPressed: () => context.go('/photos'),
            child: const Text('Open'),
          ),
        ),
        photosPreview.when(
          data: (photos) {
            if (photos.isEmpty) return const Text('No photos yet.');
            final items = photos.take(4).toList();
            return Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: i == items.length - 1 ? 0 : 8,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            items[i].imageUrl,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text(e.toString()),
        ),
        const SizedBox(height: 16),
        _InfoCard(
          title: 'About the Branch',
          body:
              'Replace this section with your official branch description (can be stored in Firestore later).',
        ),
        const SizedBox(height: 12),
        _InfoCard(
          title: 'About IEEE',
          body:
              'Replace this section with your official IEEE description (can be stored in Firestore later).',
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.action});

  final String title;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        action,
      ],
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
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
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body),
          ],
        ),
      ),
    );
  }
}
