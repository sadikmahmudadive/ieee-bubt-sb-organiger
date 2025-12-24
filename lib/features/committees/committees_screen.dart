import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/committee_member.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

final committeeMembersProvider = StreamProvider<List<CommitteeMember>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.committeeMembers)
      .orderBy('order', descending: false)
      .snapshots()
      .map((snap) => snap.docs.map(CommitteeMember.fromDoc).toList());
});

class CommitteesScreen extends ConsumerWidget {
  const CommitteesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membersAsync = ref.watch(committeeMembersProvider);

    return membersAsync.when(
      data: (members) {
        if (members.isEmpty) {
          return const _EmptyCommittee();
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: members.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final m = members[i];
            return ListTile(
              leading: CircleAvatar(
                backgroundImage: m.photoUrl == null
                    ? null
                    : NetworkImage(m.photoUrl!),
                child: m.photoUrl == null
                    ? Text(m.name.isEmpty ? '?' : m.name.substring(0, 1))
                    : null,
              ),
              title: Text(m.name),
              subtitle: Text(m.role),
              trailing: m.email == null
                  ? null
                  : const Icon(Icons.email_outlined),
              onTap: m.email == null
                  ? null
                  : () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Email: ${m.email}')),
                      );
                    },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) {
        // If the collection doesn't exist yet, Firestore can still return empty results,
        // but orderBy without indexes/field can throw.
        return _ErrorCommittee(message: e.toString());
      },
    );
  }
}

class _EmptyCommittee extends StatelessWidget {
  const _EmptyCommittee();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Committee', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'No committee members found in Firestore yet.\n\n'
          'Create a collection named "committee_members" and add documents with fields: name, role, email (optional), photoUrl (optional), order (number).',
        ),
      ],
    );
  }
}

class _ErrorCommittee extends StatelessWidget {
  const _ErrorCommittee({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Committee', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Could not load committee members.'),
        const SizedBox(height: 8),
        SelectableText(message),
        const SizedBox(height: 12),
        const Text(
          'Tip: If you see an index/orderBy error, add an "order" number field to all documents or remove ordering.',
        ),
      ],
    );
  }
}
