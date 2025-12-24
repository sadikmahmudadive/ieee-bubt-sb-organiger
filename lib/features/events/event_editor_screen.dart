import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/event.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

class EventEditorScreen extends ConsumerStatefulWidget {
  const EventEditorScreen({super.key});

  @override
  ConsumerState<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends ConsumerState<EventEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _description = TextEditingController();

  DateTime _startAt = DateTime.now().add(const Duration(days: 1));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startAt,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startAt),
    );
    if (time == null || !mounted) return;

    setState(() {
      _startAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _save() async {
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final user = ref.read(firebaseAuthProvider).currentUser;
      if (user == null) throw StateError('Not signed in');

      final e = Event(
        id: '',
        title: _title.text.trim(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        location: _location.text.trim().isEmpty ? null : _location.text.trim(),
        startAt: _startAt,
        createdBy: user.uid,
      );

      if (_startAt.isBefore(DateTime.now())) {
        throw StateError('Start time must be in the future');
      }

      final db = ref.read(firestoreProvider);
      await db.collection(FirestorePaths.events).add(e.toCreateMap());

      if (!mounted) return;
      context.pop();
    } on FirebaseException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final startLabel = DateFormat(
      'EEE, dd MMM yyyy • hh:mm a',
    ).format(_startAt.toLocal());

    return Scaffold(
      appBar: AppBar(title: const Text('Create event')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Event details',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _title,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'e.g., Workshop on Flutter',
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return 'Title is required';
                if (t.length < 3) return 'Title is too short';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _location,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Location (optional)',
                hintText: 'e.g., Room 402 / Auditorium',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'What is this event about?',
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                title: const Text('Start time'),
                subtitle: Text(startLabel),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _busy ? null : _pickStart,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: const Text('Create event'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
