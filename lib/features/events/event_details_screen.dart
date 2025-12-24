import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/event.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

class EventDetailsScreen extends ConsumerWidget {
  const EventDetailsScreen({super.key, required this.eventId});

  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(firestoreProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection(FirestorePaths.events).doc(eventId).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.active &&
            !snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final doc = snapshot.data;
        if (doc == null || !doc.exists) {
          return const Scaffold(body: Center(child: Text('Event not found.')));
        }

        final event = Event.fromDoc(doc);
        final date = DateFormat(
          'EEE, dd MMM yyyy • hh:mm a',
        ).format(event.startAt.toLocal());

        final user = ref.watch(firebaseAuthProvider).currentUser;

        return Scaffold(
          appBar: AppBar(title: const Text('Event')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                event.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Card(
                color: colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.schedule),
                          const SizedBox(width: 8),
                          Expanded(child: Text(date)),
                        ],
                      ),
                      if (event.location != null && event.location!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            children: [
                              const Icon(Icons.place_outlined),
                              const SizedBox(width: 8),
                              Expanded(child: Text(event.location!)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (event.description != null &&
                  event.description!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Details', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(event.description!),
              ],
              const SizedBox(height: 16),
              if (user != null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final db = ref.read(firestoreProvider);
                      final existing = await db
                          .collection(FirestorePaths.chatThreads)
                          .where('eventId', isEqualTo: eventId)
                          .limit(1)
                          .get();

                      if (existing.docs.isNotEmpty) {
                        final id = existing.docs.first.id;
                        if (context.mounted) context.push('/chats/thread/$id');
                        return;
                      }

                      final docRef = await db
                          .collection(FirestorePaths.chatThreads)
                          .add({
                            'isGroup': true,
                            'name': '${event.title} • Event',
                            'eventId': eventId,
                            'memberUids': [user.uid],
                            'createdBy': user.uid,
                            'createdAt': FieldValue.serverTimestamp(),
                            'lastMessageAt': FieldValue.serverTimestamp(),
                          });

                      if (context.mounted) {
                        context.push('/chats/thread/${docRef.id}');
                      }
                    },
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Open event group chat'),
                  ),
                )
              else
                Text(
                  'Sign in to join the event group chat.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
            ],
          ),
        );
      },
    );
  }
}
