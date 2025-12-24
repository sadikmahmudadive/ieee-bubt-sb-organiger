import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'app.dart';
import 'setup_required_screen.dart';
import '../services/notification_service.dart';
import '../firebase_options.dart';
import '../providers.dart';

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  late final Future<_BootstrapResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _init();
  }

  Future<_BootstrapResult> _init() async {
    WidgetsFlutterBinding.ensureInitialized();

    try {
      final prefs = await SharedPreferences.getInstance();

      try {
        await dotenv.load(fileName: '.env');
      } catch (_) {
        // .env is optional in dev; Cloudinary features will show a message.
      }

      tz.initializeTimeZones();
      await NotificationService.instance.initialize();

      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
        return _BootstrapResult(firebaseReady: true, prefs: prefs);
      } catch (e, st) {
        return _BootstrapResult(
          firebaseReady: false,
          prefs: prefs,
          error: e,
          stackTrace: st,
        );
      }
    } catch (e, st) {
      return _BootstrapResult(
        firebaseReady: false,
        prefs: null,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BootstrapResult>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        if (data == null) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: Text('Failed to start app.'))),
          );
        }

        if (!data.firebaseReady) {
          if (data.prefs == null) {
            return SetupRequiredApp(
              error: data.error,
              stackTrace: data.stackTrace,
            );
          }

          return ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(data.prefs!),
            ],
            child: SetupRequiredApp(
              error: data.error,
              stackTrace: data.stackTrace,
            ),
          );
        }

        if (data.prefs == null) {
          return const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('Failed to initialize storage.')),
            ),
          );
        }

        return ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(data.prefs!)],
          child: const App(),
        );
      },
    );
  }
}

class _BootstrapResult {
  const _BootstrapResult({
    required this.firebaseReady,
    required this.prefs,
    this.error,
    this.stackTrace,
  });

  final bool firebaseReady;
  final SharedPreferences? prefs;
  final Object? error;
  final StackTrace? stackTrace;
}
