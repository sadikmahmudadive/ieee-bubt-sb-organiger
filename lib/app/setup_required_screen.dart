import 'package:flutter/material.dart';

class SetupRequiredApp extends StatelessWidget {
  const SetupRequiredApp({super.key, this.error, this.stackTrace});

  final Object? error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Setup Required',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: SetupRequiredScreen(error: error),
    );
  }
}

class SetupRequiredScreen extends StatelessWidget {
  const SetupRequiredScreen({super.key, this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup required')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const Text(
              'Firebase is not configured for this app yet.\n\n'
              'To enable Authentication + Database, run FlutterFire configuration and add the platform config files.\n',
            ),
            const Text('Checklist:'),
            const SizedBox(height: 8),
            const Text(
              '1) Install FlutterFire CLI: dart pub global activate flutterfire_cli',
            ),
            const Text('2) In this project: flutterfire configure'),
            const Text('3) Enable Email/Password in Firebase Auth'),
            const Text('4) Create Firestore database (production/test mode)'),
            const SizedBox(height: 12),
            if (error != null) ...[
              const Text('Startup error:'),
              const SizedBox(height: 8),
              SelectableText(error.toString()),
            ],
          ],
        ),
      ),
    );
  }
}
