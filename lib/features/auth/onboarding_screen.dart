import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key, this.from});

  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final encodedFrom = Uri.encodeComponent(from ?? '/');

    Future<void> markSeen() async {
      await ref
          .read(sharedPreferencesProvider)
          .setBool(onboardingSeenKey, true);
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  const Spacer(),
                  Center(
                    child: Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.groups_2_outlined,
                        size: 96,
                        color: cs.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Welcome to IEEE Organizer',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Manage events, connect with committees, and stay organized in one place.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: () async {
                      await markSeen();
                      if (!context.mounted) return;
                      context.go('/auth/sign-in?from=$encodedFrom');
                    },
                    child: const Text('Log in'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () async {
                      await markSeen();
                      if (!context.mounted) return;
                      context.go('/auth/register?from=$encodedFrom');
                    },
                    child: const Text('Create an account'),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
