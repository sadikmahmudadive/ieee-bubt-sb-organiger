import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';
import '../features/chat/incoming_call_listener.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep listening for incoming call offers to surface notifications.
    ref.watch(incomingCallListenerProvider);

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'IEEE BUBT SB Organizer',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
