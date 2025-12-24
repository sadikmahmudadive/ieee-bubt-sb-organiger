import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/event.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';
import '../../services/notification_service.dart';

final eventsProvider = StreamProvider<List<Event>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.events)
      .orderBy('startAt', descending: false)
      .snapshots()
      .map((snap) => snap.docs.map(Event.fromDoc).toList());
});

class EventsScreen extends ConsumerWidget {
  const EventsScreen({super.key});

  Future<void> _pickReminder(BuildContext context, Event e) async {
    final choice = await showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              ListTile(title: Text('Set reminder')),
              Divider(height: 1),
              _ReminderOption(label: '5 minutes before', minutes: 5),
              _ReminderOption(label: '30 minutes before', minutes: 30),
              _ReminderOption(label: '1 hour before', minutes: 60),
              _ReminderOption(label: '1 day before', minutes: 24 * 60),
              SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (choice == null) return;

    final scheduled = e.startAt.subtract(choice);
    if (scheduled.isBefore(DateTime.now())) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That reminder time is already in the past.'),
          ),
        );
      }
      return;
    }

    await NotificationService.instance.scheduleReminder(
      id: e.id.hashCode,
      title: 'Event reminder',
      body: e.title,
      scheduledAt: scheduled,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Reminder set.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(firebaseAuthProvider);
    final eventsAsync = ref.watch(eventsProvider);

    return Scaffold(
      body: eventsAsync.when(
        data: (events) {
          if (events.isEmpty) {
            return const _EmptyEvents();
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: events.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final e = events[i];
              final date = DateFormat(
                'EEE, dd MMM yyyy • hh:mm a',
              ).format(e.startAt);

              return Card(
                child: ListTile(
                  title: Text(e.title),
                  subtitle: Text(
                    '$date${e.location == null ? '' : "\n${e.location}"}',
                  ),
                  isThreeLine: e.location != null,
                  onTap: () => context.push('/events/${e.id}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Set reminder',
                        onPressed: () => _pickReminder(context, e),
                        icon: const Icon(Icons.notifications_active_outlined),
                      ),
                      IconButton(
                        tooltip: 'Cancel reminder',
                        onPressed: () async {
                          await NotificationService.instance.cancel(
                            e.id.hashCode,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Reminder cancelled.'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.notifications_off_outlined),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorEvents(message: e.toString()),
      ),
      floatingActionButton: auth.currentUser == null
          ? null
          : FloatingActionButton(
              onPressed: () => context.push('/events/new'),
              child: const Icon(Icons.add),
            ),
    );
  }
}

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Events', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'No events yet. Committee members can create events after signing in.',
        ),
      ],
    );
  }
}

class _ErrorEvents extends StatelessWidget {
  const _ErrorEvents({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Events', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Could not load events.'),
        const SizedBox(height: 8),
        SelectableText(message),
      ],
    );
  }
}

class _ReminderOption extends StatelessWidget {
  const _ReminderOption({required this.label, required this.minutes});

  final String label;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).pop(Duration(minutes: minutes)),
    );
  }
}
