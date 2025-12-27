import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  FutureOr<void> Function(String?)? _onSelect;

  Future<void> initialize({FutureOr<void> Function(String?)? onSelect}) async {
    _onSelect = onSelect;
    // This app currently configures local notifications only for Android.
    // On Windows/macOS/Linux/iOS/web we skip initialization to avoid
    // platform-specific configuration errors.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) async {
        await _onSelect?.call(response.payload);
      },
    );

    // Handle notification tap that launched the app from a terminated state.
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    final launchedFromNotification = launchDetails?.didNotificationLaunchApp;
    final launchPayload = launchDetails?.notificationResponse?.payload;
    if (launchedFromNotification == true && launchPayload != null) {
      await _onSelect?.call(launchPayload);
    }

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    const androidChannel = AndroidNotificationChannel(
      'events',
      'Event reminders',
      description: 'Reminders for upcoming IEEE BUBT SB events',
      importance: Importance.high,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);

    const callsChannel = AndroidNotificationChannel(
      'calls',
      'Call alerts',
      description: 'Incoming and outgoing call notifications',
      importance: Importance.max,
      playSound: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(callsChannel);
  }

  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    final when = tz.TZDateTime.from(scheduledAt, tz.local);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      when,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'events',
          'Event reminders',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  Future<void> cancel(int id) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Future.value();
    }
    return _plugin.cancel(id);
  }

  Future<void> showCallAlert({
    required String title,
    required String body,
    int id = 1001,
    String? payload,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Call alerts',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          playSound: true,
          fullScreenIntent: true,
        ),
      ),
      payload: payload,
    );
  }
}
