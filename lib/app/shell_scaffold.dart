import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../features/profile/profile_screen.dart';

class ShellScaffold extends ConsumerWidget {
  const ShellScaffold({super.key, required this.child});

  final Widget child;

  int _indexForLocation(String location) {
    if (location.startsWith('/committees')) return 1;
    if (location.startsWith('/events')) return 2;
    if (location.startsWith('/chats')) return 3;
    if (location.startsWith('/photos')) return 4;
    return 0;
  }

  void _goForIndex(BuildContext context, int index) {
    switch (index) {
      case 0:
        context.go('/');
        return;
      case 1:
        context.go('/committees');
        return;
      case 2:
        context.go('/events');
        return;
      case 3:
        context.go('/chats');
        return;
      case 4:
        context.go('/photos');
        return;
    }
  }

  List<NavigationDestination> _destinations() {
    return const [
      NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: 'Home',
      ),
      NavigationDestination(
        icon: Icon(Icons.groups_outlined),
        selectedIcon: Icon(Icons.groups),
        label: 'Committee',
      ),
      NavigationDestination(
        icon: Icon(Icons.event_outlined),
        selectedIcon: Icon(Icons.event),
        label: 'Events',
      ),
      NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble),
        label: 'Chats',
      ),
      NavigationDestination(
        icon: Icon(Icons.photo_library_outlined),
        selectedIcon: Icon(Icons.photo_library),
        label: 'Photos',
      ),
    ];
  }

  List<NavigationRailDestination> _railDestinations() {
    return const [
      NavigationRailDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: Text('Home'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.groups_outlined),
        selectedIcon: Icon(Icons.groups),
        label: Text('Committee'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.event_outlined),
        selectedIcon: Icon(Icons.event),
        label: Text('Events'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble),
        label: Text('Chats'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.photo_library_outlined),
        selectedIcon: Icon(Icons.photo_library),
        label: Text('Photos'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();
    final currentIndex = _indexForLocation(location);

    final auth = ref.watch(firebaseAuthProvider);

    final destinations = _destinations();
    final railDestinations = _railDestinations();
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    final actions = <Widget>[
      if (auth.currentUser == null)
        FilledButton.tonal(
          onPressed: () => context.push(
            '/auth/sign-in?from=${Uri.encodeComponent(location)}',
          ),
          child: const Text('Sign in'),
        )
      else ...[
        Consumer(
          builder: (context, ref, _) {
            final profileAsync = ref.watch(currentUserProfileProvider);
            return IconButton(
              tooltip: 'Profile',
              onPressed: () => context.push('/profile'),
              icon: profileAsync.when(
                data: (p) {
                  final url = p?.photoUrl;
                  if (url == null || url.isEmpty) {
                    return const Icon(Icons.account_circle);
                  }
                  return CircleAvatar(
                    backgroundImage: NetworkImage(url),
                    radius: 14,
                  );
                },
                loading: () => const Icon(Icons.account_circle),
                error: (_, _) => const Icon(Icons.account_circle),
              ),
            );
          },
        ),
        PopupMenuButton<String>(
          tooltip: 'Menu',
          onSelected: (v) async {
            if (v == 'sign_out') {
              await auth.signOut();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'sign_out', child: Text('Sign out')),
          ],
        ),
      ],
      const SizedBox(width: 8),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('IEEE BUBT SB'), actions: actions),
      body: isWide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: currentIndex,
                  onDestinationSelected: (i) => _goForIndex(context, i),
                  labelType: NavigationRailLabelType.all,
                  destinations: railDestinations,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            )
          : child,
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: currentIndex,
              onDestinationSelected: (i) => _goForIndex(context, i),
              destinations: destinations,
            ),
    );
  }
}
