import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/widgets.dart';

import '../firebase_options.dart';
import '../app/router.dart';
import 'firestore_paths.dart';
import 'notification_service.dart';

/// Background entry point for Firebase Messaging.
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final data = message.data;
  final threadId = (data['threadId'] ?? data['callId'])?.toString();
  final callType = (data['callType'] ?? data['type'] ?? 'audio').toString();
  final isCall = data['action'] == 'incoming_call' || threadId != null;
  if (!isCall) return;

  final callerName = data['callerName'] ?? 'Incoming call';
  final title = callType == 'video'
      ? 'Incoming video call'
      : 'Incoming voice call';

  await NotificationService.instance.initialize();
  await NotificationService.instance.showCallAlert(
    title: title,
    body: callerName.toString(),
    payload: jsonEncode({
      ...data,
      if (threadId != null) 'threadId': threadId,
      'callType': callType,
    }),
  );
}

class PushService {
  PushService._();

  static final PushService instance = PushService._();

  late final FirebaseMessaging _messaging;
  bool _initialized = false;
  FirebaseAuth? _auth;
  FirebaseFirestore? _db;

  Future<void> initialize({
    required FirebaseAuth auth,
    required FirebaseFirestore db,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _auth = auth;
    _db = db;
    _messaging = FirebaseMessaging.instance;

    await _messaging.requestPermission(alert: true, sound: true, badge: true);
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    await _saveToken();
    _messaging.onTokenRefresh.listen((token) => _saveToken(token: token));

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _handleNavigation(message.data),
    );

    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      await _handleNavigation(initial.data);
    }
  }

  Future<void> handleNotificationTap(String? payload) async {
    if (payload == null) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      await _handleNavigation(data);
    } catch (_) {
      // Ignore malformed payloads.
    }
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    final threadId = (data['threadId'] ?? data['callId'])?.toString();
    final type = (data['callType'] ?? data['type'] ?? 'audio').toString();
    final isCall = data['action'] == 'incoming_call' || threadId != null;
    if (!isCall) return;

    final callerName = (data['callerName'] ?? 'Incoming call').toString();
    final title = type == 'video'
        ? 'Incoming video call'
        : 'Incoming voice call';

    await NotificationService.instance.showCallAlert(
      title: title,
      body: callerName,
      payload: jsonEncode({
        ...data,
        if (threadId != null) 'threadId': threadId,
        'callType': type,
      }),
    );
  }

  Future<void> _handleNavigation(Map<String, dynamic> data) async {
    final threadId = (data['threadId'] ?? data['callId'])?.toString();
    final type = (data['callType'] ?? data['type'] ?? 'audio').toString();
    if (threadId == null) return;
    final route = '/chats/thread/$threadId/call/$type';

    final context = rootNavigatorKey.currentContext;
    if (context == null) return;

    GoRouter.of(context).go(route);
  }

  Future<void> _saveToken({String? token}) async {
    final uid = _auth?.currentUser?.uid;
    if (uid == null) return;
    final value = token ?? await _messaging.getToken();
    if (value == null) return;

    await _db?.collection(FirestorePaths.users).doc(uid).set({
      'fcmTokens': FieldValue.arrayUnion([
        {
          'token': value,
          'platform': defaultTargetPlatform.name,
          'updatedAt': Timestamp.now(),
        },
      ]),
    }, SetOptions(merge: true));
  }
}
