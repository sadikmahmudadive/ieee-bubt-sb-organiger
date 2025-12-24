import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/photo_post.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';

final photoPostsProvider = StreamProvider<List<PhotoPost>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.photoPosts)
      .orderBy('uploadedAt', descending: true)
      .limit(60)
      .snapshots()
      .map((s) => s.docs.map(PhotoPost.fromDoc).toList());
});

class PhotosScreen extends ConsumerStatefulWidget {
  const PhotosScreen({super.key});

  @override
  ConsumerState<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends ConsumerState<PhotosScreen> {
  bool _uploading = false;

  Future<void> _upload() async {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    final cloudinary = ref.read(cloudinaryProvider);
    if (!cloudinary.isConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cloudinary is not configured. Fill .env values first.',
          ),
        ),
      );
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;

    final caption = await _askCaption();
    if (!mounted) return;

    setState(() => _uploading = true);

    try {
      final url = await cloudinary.uploadImage(picked);
      final db = ref.read(firestoreProvider);
      await db.collection(FirestorePaths.photoPosts).add({
        'imageUrl': url,
        'caption': caption,
        'uploadedBy': user.uid,
        'uploadedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Photo uploaded.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<String?> _askCaption() async {
    final controller = TextEditingController();
    final res = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Caption (optional)'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Write something…'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return res;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(firebaseAuthProvider);
    final postsAsync = ref.watch(photoPostsProvider);

    return Scaffold(
      body: postsAsync.when(
        data: (posts) {
          if (posts.isEmpty) {
            return const _EmptyPhotos();
          }

          return LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final crossAxisCount = w >= 1100
                  ? 5
                  : w >= 900
                  ? 4
                  : w >= 650
                  ? 3
                  : 2;

              final scrim = Theme.of(context).colorScheme.scrim.withAlpha(140);

              return GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemCount: posts.length,
                itemBuilder: (context, i) {
                  final p = posts[i];
                  return Card(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          p.imageUrl,
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          },
                          errorBuilder: (context, _, _) {
                            return const Center(
                              child: Icon(Icons.broken_image_outlined),
                            );
                          },
                        ),
                        if ((p.caption ?? '').isNotEmpty)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: scrim),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  p.caption!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(e.toString())),
      ),
      floatingActionButton: auth.currentUser == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _uploading ? null : _upload,
              icon: _uploading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload),
              label: const Text('Upload'),
            ),
    );
  }
}

class _EmptyPhotos extends StatelessWidget {
  const _EmptyPhotos();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Photo Corner', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'No photos yet. Sign in and upload the first memory for the branch.',
        ),
      ],
    );
  }
}
