import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../features/auth/forgot_password_screen.dart';
import '../features/auth/onboarding_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/home/home_screen.dart';
import '../features/committees/committees_screen.dart';
import '../features/events/event_editor_screen.dart';
import '../features/events/event_details_screen.dart';
import '../features/events/events_screen.dart';
import '../features/chat/chat_thread_screen.dart';
import '../features/chat/chats_screen.dart';
import '../features/chat/create_group_screen.dart';
import '../features/photos/photos_screen.dart';
import '../features/profile/profile_screen.dart';
import 'shell_scaffold.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authStream = ref.watch(firebaseAuthProvider).authStateChanges();

  return GoRouter(
    initialLocation: '/',
    refreshListenable: GoRouterRefreshStream(authStream),
    redirect: (context, state) {
      final user = ref.read(firebaseAuthProvider).currentUser;
      final isAuthed = user != null;

      final loc = state.matchedLocation;
      final isAuthRoute = loc.startsWith('/auth');
      final isOnboarding = loc == '/onboarding';
      final onboardingSeen = ref.read(onboardingSeenProvider);

      if (!isAuthed && !isAuthRoute && !isOnboarding) {
        final dest = Uri.encodeComponent(state.uri.toString());
        if (onboardingSeen) {
          return '/auth/sign-in?from=$dest';
        }
        return '/onboarding?from=$dest';
      }
      if (isAuthed && (isAuthRoute || isOnboarding)) {
        return '/';
      }
      return null;
    },
    routes: [
      ShellRoute(
        builder: (context, state, child) => ShellScaffold(child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/committees',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: CommitteesScreen()),
          ),
          GoRoute(
            path: '/events',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: EventsScreen()),
            routes: [
              GoRoute(
                path: 'new',
                builder: (context, state) => const EventEditorScreen(),
              ),
              GoRoute(
                path: ':id',
                builder: (context, state) =>
                    EventDetailsScreen(eventId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/chats',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: ChatsScreen()),
            routes: [
              GoRoute(
                path: 'create-group',
                builder: (context, state) => const CreateGroupScreen(),
              ),
              GoRoute(
                path: 'thread/:id',
                builder: (context, state) =>
                    ChatThreadScreen(threadId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/photos',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: PhotosScreen()),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) =>
            OnboardingScreen(from: state.uri.queryParameters['from']),
      ),
      GoRoute(
        path: '/auth/sign-in',
        builder: (context, state) =>
            SignInScreen(from: state.uri.queryParameters['from']),
      ),
      GoRoute(
        path: '/auth/forgot-password',
        builder: (context, state) =>
            ForgotPasswordScreen(from: state.uri.queryParameters['from']),
      ),
      GoRoute(
        path: '/auth/register',
        builder: (context, state) =>
            RegisterScreen(from: state.uri.queryParameters['from']),
      ),
    ],
  );
});

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
