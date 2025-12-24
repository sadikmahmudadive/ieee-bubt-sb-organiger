import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/user_profile.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

final currentUserProfileProvider = StreamProvider<UserProfile?>((ref) {
  final user = ref.watch(firebaseAuthProvider).currentUser;
  if (user == null) return Stream<UserProfile?>.value(null);

  final db = ref.watch(firestoreProvider);
  return db.collection(FirestorePaths.users).doc(user.uid).snapshots().map((d) {
    if (!d.exists) return null;
    return UserProfile.fromDoc(d);
  });
});

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _name = TextEditingController();
  bool _saving = false;
  bool _notifications = true;
  bool _readReceipts = true;
  bool _typingIndicators = true;
  bool _followSystemTheme = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    final displayName = _name.text.trim();
    if (displayName.isEmpty) return;

    setState(() => _saving = true);
    try {
      final db = ref.read(firestoreProvider);
      await db.collection(FirestorePaths.users).doc(user.uid).set({
        'displayName': displayName,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await user.updateDisplayName(displayName);

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeAvatar() async {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    final cloudinary = ref.read(cloudinaryProvider);
    if (!cloudinary.isConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloudinary is not configured (.env).')),
      );
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() => _saving = true);
    try {
      final url = await cloudinary.uploadImage(picked);
      final db = ref.read(firestoreProvider);
      await db.collection(FirestorePaths.users).doc(user.uid).set({
        'photoUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Photo updated.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(firebaseAuthProvider);
    final profileAsync = ref.watch(currentUserProfileProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (auth.currentUser == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('Profile & Settings')),
      body: profileAsync.when(
        data: (p) {
          final fallbackEmail = auth.currentUser?.email ?? '';
          final displayName = (p?.displayName.isNotEmpty ?? false)
              ? p!.displayName
              : (auth.currentUser?.displayName ?? '');

          if (_name.text.isEmpty && displayName.isNotEmpty) {
            _name.text = displayName;
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                elevation: 0,
                color: cs.primaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundImage:
                            (p?.photoUrl == null || p!.photoUrl!.isEmpty)
                            ? null
                            : NetworkImage(p.photoUrl!),
                        child: (p?.photoUrl == null || p!.photoUrl!.isEmpty)
                            ? const Icon(Icons.person, size: 32)
                            : null,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName.isEmpty
                                  ? 'Your profile'
                                  : displayName,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              p?.email.isNotEmpty ?? false
                                  ? p!.email
                                  : fallbackEmail,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onPrimaryContainer.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: _saving ? null : _changeAvatar,
                                  icon: const Icon(Icons.photo_camera_outlined),
                                  label: const Text('Change photo'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _saving
                                      ? null
                                      : () async {
                                          await auth.signOut();
                                          if (!context.mounted) return;
                                          Navigator.of(context).pop();
                                        },
                                  icon: const Icon(Icons.logout),
                                  label: const Text('Sign out'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Account', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: const Text('Save changes'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      value: _notifications,
                      onChanged: (v) => setState(() => _notifications = v),
                      title: const Text('Notifications'),
                      subtitle: const Text(
                        'Get alerts for mentions and replies',
                      ),
                    ),
                    SwitchListTile.adaptive(
                      value: _readReceipts,
                      onChanged: (v) => setState(() => _readReceipts = v),
                      title: const Text('Read receipts'),
                      subtitle: const Text('Let people see when you read'),
                    ),
                    SwitchListTile.adaptive(
                      value: _typingIndicators,
                      onChanged: (v) => setState(() => _typingIndicators = v),
                      title: const Text('Typing indicators'),
                      subtitle: const Text('Show when you are typing'),
                    ),
                    SwitchListTile.adaptive(
                      value: _followSystemTheme,
                      onChanged: (v) => setState(() => _followSystemTheme = v),
                      title: const Text('Follow system theme'),
                      subtitle: const Text('Match light/dark with system'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: const [
                    ListTile(
                      leading: Icon(Icons.privacy_tip_outlined),
                      title: Text('Privacy and safety'),
                      subtitle: Text('Control who can reach you'),
                    ),
                    Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.help_outline),
                      title: Text('Help center'),
                      subtitle: Text('FAQs and support'),
                    ),
                    Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('About'),
                      subtitle: Text('Version and legal'),
                    ),
                  ],
                ),
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
