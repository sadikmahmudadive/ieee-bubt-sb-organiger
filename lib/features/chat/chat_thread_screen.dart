import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../../models/chat_message.dart';
import '../../models/chat_thread.dart';
import '../../models/user_profile.dart';
import '../../providers.dart';
import '../../services/firestore_paths.dart';
import 'user_profile_providers.dart';

final threadProvider = StreamProvider.autoDispose.family<ChatThread?, String>((
  ref,
  threadId,
) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() {
    timer = Timer(const Duration(minutes: 2), link.close);
  });
  ref.onResume(() {
    timer?.cancel();
    timer = null;
  });
  ref.onDispose(() {
    timer?.cancel();
  });

  final db = ref.watch(firestoreProvider);
  return db
      .collection(FirestorePaths.chatThreads)
      .doc(threadId)
      .snapshots()
      .map((d) {
        if (!d.exists) return null;
        return ChatThread.fromDoc(d);
      });
});

final threadMessagesProvider = StreamProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, threadId) {
      final link = ref.keepAlive();
      Timer? timer;
      ref.onCancel(() {
        timer = Timer(const Duration(minutes: 2), link.close);
      });
      ref.onResume(() {
        timer?.cancel();
        timer = null;
      });
      ref.onDispose(() {
        timer?.cancel();
      });

      final db = ref.watch(firestoreProvider);
      return db
          .collection(FirestorePaths.threadMessages(threadId))
          .orderBy('sentAt', descending: true)
          .limit(30)
          .snapshots()
          .map((s) => s.docs.map(ChatMessage.fromDoc).toList());
    });

const _pageSize = 25;

class ThreadMessagesState {
  const ThreadMessagesState({
    required this.messages,
    required this.isLoadingMore,
    required this.hasMore,
  });

  final List<ChatMessage> messages;
  final bool isLoadingMore;
  final bool hasMore;

  ThreadMessagesState copyWith({
    List<ChatMessage>? messages,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return ThreadMessagesState(
      messages: messages ?? this.messages,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

final threadMessagesControllerProvider =
    AutoDisposeAsyncNotifierProviderFamily<
      _ThreadMessagesController,
      ThreadMessagesState,
      String
    >(_ThreadMessagesController.new);

class _ThreadMessagesController
    extends AutoDisposeFamilyAsyncNotifier<ThreadMessagesState, String> {
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  late String _threadId;

  @override
  FutureOr<ThreadMessagesState> build(String arg) async {
    _threadId = arg;
    _listenFirstPage();
    return const ThreadMessagesState(
      messages: [],
      isLoadingMore: false,
      hasMore: true,
    );
  }

  void _listenFirstPage() {
    final db = ref.read(firestoreProvider);
    _sub?.cancel();
    _sub = db
        .collection(FirestorePaths.threadMessages(_threadId))
        .orderBy('sentAt', descending: true)
        .limit(_pageSize)
        .snapshots()
        .listen((snap) {
          final msgs = snap.docs.map(ChatMessage.fromDoc).toList();
          _lastDoc = snap.docs.isNotEmpty ? snap.docs.last : _lastDoc;
          final hasMore = snap.docs.length == _pageSize;
          _mergeAndEmit(msgs, forceHasMore: hasMore);
        });

    ref.onDispose(() {
      _sub?.cancel();
    });
  }

  void _mergeAndEmit(List<ChatMessage> incoming, {bool? forceHasMore}) {
    final current = state.value?.messages ?? [];
    final map = {for (final m in current) m.id: m};
    for (final m in incoming) {
      map[m.id] = m;
    }
    final merged = map.values.toList()
      ..sort((a, b) {
        final at = a.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });

    state = AsyncData(
      ThreadMessagesState(
        messages: merged,
        isLoadingMore: state.value?.isLoadingMore ?? false,
        hasMore: forceHasMore ?? state.value?.hasMore ?? true,
      ),
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.isLoadingMore || !current.hasMore) return;
    if (_lastDoc == null) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final db = ref.read(firestoreProvider);
      final snap = await db
          .collection(FirestorePaths.threadMessages(_threadId))
          .orderBy('sentAt', descending: true)
          .startAfterDocument(_lastDoc!)
          .limit(_pageSize)
          .get();

      if (snap.docs.isNotEmpty) {
        _lastDoc = snap.docs.last;
        _mergeAndEmit(
          snap.docs.map(ChatMessage.fromDoc).toList(),
          forceHasMore: snap.docs.length == _pageSize,
        );
      } else {
        state = AsyncData(current.copyWith(hasMore: false));
      }
    } catch (e, st) {
      state = AsyncError(e, st);
    } finally {
      final latest = state.value;
      if (latest != null) {
        state = AsyncData(latest.copyWith(isLoadingMore: false));
      }
    }
  }

  String addOptimisticMessage({
    String? forcedId,
    required String text,
    required String senderUid,
    required String? imageUrl,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? audioUrl,
    int? audioDurationSec,
    String? replyToMessageId,
    String? replyToText,
    String? replyToSenderUid,
    bool edited = false,
    bool deleted = false,
  }) {
    final tempId = forcedId ?? 'temp-${const Uuid().v4()}';
    final optimistic = ChatMessage(
      id: tempId,
      senderUid: senderUid,
      text: text,
      imageUrl: imageUrl,
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      audioUrl: audioUrl,
      audioDurationSec: audioDurationSec,
      replyToMessageId: replyToMessageId,
      replyToText: replyToText,
      replyToSenderUid: replyToSenderUid,
      sentAt: DateTime.now(),
      pending: true,
      edited: edited,
      deleted: deleted,
    );
    final current =
        state.value ??
        const ThreadMessagesState(
          messages: [],
          isLoadingMore: false,
          hasMore: true,
        );
    final merged = [optimistic, ...current.messages];
    merged.sort((a, b) {
      final at = a.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    state = AsyncData(current.copyWith(messages: merged));
    return tempId;
  }

  void removeOptimistic(String tempId) {
    final current = state.value;
    if (current == null) return;
    final filtered = current.messages.where((m) => m.id != tempId).toList();
    state = AsyncData(current.copyWith(messages: filtered));
  }
}

class ChatThreadScreen extends ConsumerStatefulWidget {
  const ChatThreadScreen({
    super.key,
    required this.threadId,
    this.embedded = false,
  });

  final String threadId;
  final bool embedded;

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _OutboxEntry {
  const _OutboxEntry({
    required this.tempId,
    required this.createdAtMs,
    required this.text,
    this.imageUrl,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.audioUrl,
    this.audioDurationSec,
    this.replyToMessageId,
    this.replyToText,
    this.replyToSenderUid,
    this.attempts = 0,
    this.nextAttemptAtMs,
  });

  final String tempId;
  final int createdAtMs;
  final String text;
  final String? imageUrl;
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? audioUrl;
  final int? audioDurationSec;
  final String? replyToMessageId;
  final String? replyToText;
  final String? replyToSenderUid;
  final int attempts;
  final int? nextAttemptAtMs;

  Map<String, dynamic> toJson() => {
    'tempId': tempId,
    'createdAtMs': createdAtMs,
    'text': text,
    'imageUrl': imageUrl,
    'fileUrl': fileUrl,
    'fileName': fileName,
    'fileSize': fileSize,
    'audioUrl': audioUrl,
    'audioDurationSec': audioDurationSec,
    'replyToMessageId': replyToMessageId,
    'replyToText': replyToText,
    'replyToSenderUid': replyToSenderUid,
    'attempts': attempts,
    'nextAttemptAtMs': nextAttemptAtMs,
  };

  factory _OutboxEntry.fromJson(Map<String, dynamic> json) {
    return _OutboxEntry(
      tempId: (json['tempId'] ?? '').toString(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      text: (json['text'] ?? '').toString(),
      imageUrl: json['imageUrl'] as String?,
      fileUrl: json['fileUrl'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      audioUrl: json['audioUrl'] as String?,
      audioDurationSec: (json['audioDurationSec'] as num?)?.toInt(),
      replyToMessageId: json['replyToMessageId'] as String?,
      replyToText: json['replyToText'] as String?,
      replyToSenderUid: json['replyToSenderUid'] as String?,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAtMs: (json['nextAttemptAtMs'] as num?)?.toInt(),
    );
  }

  _OutboxEntry copyWith({int? attempts, int? nextAttemptAtMs}) {
    return _OutboxEntry(
      tempId: tempId,
      createdAtMs: createdAtMs,
      text: text,
      imageUrl: imageUrl,
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      audioUrl: audioUrl,
      audioDurationSec: audioDurationSec,
      replyToMessageId: replyToMessageId,
      replyToText: replyToText,
      replyToSenderUid: replyToSenderUid,
      attempts: attempts ?? this.attempts,
      nextAttemptAtMs: nextAttemptAtMs,
    );
  }
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen>
    with SingleTickerProviderStateMixin {
  final _text = TextEditingController();
  final _focusNode = FocusNode();
  final _gifSearch = TextEditingController();
  final _gifSearchFocusNode = FocusNode();
  bool _sending = false;
  Timer? _typingTimer;
  final _scrollController = ScrollController();
  bool _showJumpToLatest = false;
  double _sendScale = 1;
  ChatMessage? _replyingTo;
  Timer? _outboxPump;
  final Map<String, _OutboxEntry> _outbox = {};
  final Set<String> _outboxInFlight = {};
  final Set<String> _failedTempIds = {};

  late final TabController _trayTabController;
  bool _trayOpen = false;
  bool _actionsOpen = false;
  Timer? _gifDebounce;
  bool _gifLoading = false;
  String? _gifError;
  List<_GifItem> _gifItems = const [];

  static const Duration _firestoreWriteTimeout = Duration(seconds: 8);
  static const Duration _firestoreReadTimeout = Duration(seconds: 5);
  static const Duration _uploadTimeout = Duration(seconds: 25);
  static const Duration _downloadUrlTimeout = Duration(seconds: 10);

  static const double _trayHeight = 320;
  static const double _composerPadClosed = 108;
  static const double _composerPadActions = _composerPadClosed + 56;
  static const double _composerPadOpen = _composerPadClosed + _trayHeight;

  String get _outboxPrefsKey => 'chat_outbox:${widget.threadId}';

  int _backoffMsForAttempt(int attempt) {
    final capped = attempt.clamp(1, 6);
    final base = 2000;
    return base * (1 << (capped - 1));
  }

  Future<void> _saveOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _outbox.values.toList()
      ..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    await prefs.setString(
      _outboxPrefsKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _restoreOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxPrefsKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _outbox.clear();
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final entry = _OutboxEntry.fromJson(item);
          if (entry.tempId.isNotEmpty) _outbox[entry.tempId] = entry;
        } else if (item is Map) {
          final entry = _OutboxEntry.fromJson(item.cast<String, dynamic>());
          if (entry.tempId.isNotEmpty) _outbox[entry.tempId] = entry;
        }
      }
    } catch (_) {
      return;
    }

    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    final messagesState = ref
        .read(threadMessagesControllerProvider(widget.threadId))
        .valueOrNull;
    final existingIds = {
      for (final m in messagesState?.messages ?? const <ChatMessage>[]) m.id,
    };

    final messages = ref.read(
      threadMessagesControllerProvider(widget.threadId).notifier,
    );
    for (final entry in _outbox.values) {
      if (existingIds.contains(entry.tempId)) continue;
      messages.addOptimisticMessage(
        forcedId: entry.tempId,
        text: entry.text,
        senderUid: user.uid,
        imageUrl: entry.imageUrl,
        fileUrl: entry.fileUrl,
        fileName: entry.fileName,
        fileSize: entry.fileSize,
        audioUrl: entry.audioUrl,
        audioDurationSec: entry.audioDurationSec,
        replyToMessageId: entry.replyToMessageId,
        replyToText: entry.replyToText,
        replyToSenderUid: entry.replyToSenderUid,
      );
    }

    if (mounted) setState(() {});
  }

  Future<void> _enqueueOutboxAndOptimistic({
    required String text,
    String? imageUrl,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? audioUrl,
    int? audioDurationSec,
    ChatMessage? reply,
  }) async {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    final tempId = 'temp-${const Uuid().v4()}';
    final entry = _OutboxEntry(
      tempId: tempId,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      text: text,
      imageUrl: imageUrl,
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      audioUrl: audioUrl,
      audioDurationSec: audioDurationSec,
      replyToMessageId: reply?.id,
      replyToText: reply?.text,
      replyToSenderUid: reply?.senderUid,
      attempts: 0,
      nextAttemptAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    _outbox[tempId] = entry;
    await _saveOutbox();

    final messages = ref.read(
      threadMessagesControllerProvider(widget.threadId).notifier,
    );
    messages.addOptimisticMessage(
      forcedId: tempId,
      text: text,
      senderUid: user.uid,
      imageUrl: imageUrl,
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      audioUrl: audioUrl,
      audioDurationSec: audioDurationSec,
      replyToMessageId: reply?.id,
      replyToText: reply?.text,
      replyToSenderUid: reply?.senderUid,
    );

    _failedTempIds.remove(tempId);
    if (mounted) setState(() {});
  }

  Future<void> _attemptSendOutboxEntry(_OutboxEntry entry) async {
    if (!mounted) return;
    if (_outboxInFlight.contains(entry.tempId)) return;

    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    _outboxInFlight.add(entry.tempId);
    try {
      final db = ref.read(firestoreProvider);
      final messageRef = db
          .collection(FirestorePaths.threadMessages(widget.threadId))
          .doc(entry.tempId);

      final existing = await messageRef.get().timeout(_firestoreReadTimeout);
      if (!existing.exists) {
        await messageRef
            .set({
              'senderUid': user.uid,
              'text': entry.text,
              'imageUrl': entry.imageUrl,
              'fileUrl': entry.fileUrl,
              'fileName': entry.fileName,
              'fileSize': entry.fileSize,
              'audioUrl': entry.audioUrl,
              'audioDurationSec': entry.audioDurationSec,
              'replyToMessageId': entry.replyToMessageId,
              'replyToText': entry.replyToText,
              'replyToSenderUid': entry.replyToSenderUid,
              'deleted': false,
              'edited': false,
              'sentAt': FieldValue.serverTimestamp(),
            })
            .timeout(_firestoreWriteTimeout);
      }

      await db
          .collection(FirestorePaths.chatThreads)
          .doc(widget.threadId)
          .set({
            'lastMessageText': entry.text.trim().isNotEmpty
                ? entry.text
                : (entry.imageUrl != null
                      ? 'GIF'
                      : (entry.audioUrl != null
                            ? 'Voice note'
                            : (entry.fileName ?? 'Attachment'))),
            'lastMessageAt': FieldValue.serverTimestamp(),
            'memberReads': {user.uid: FieldValue.serverTimestamp()},
            'typing': {user.uid: false},
          }, SetOptions(merge: true))
          .timeout(_firestoreWriteTimeout);

      _outbox.remove(entry.tempId);
      _failedTempIds.remove(entry.tempId);
      await _saveOutbox();
    } catch (_) {
      final updatedAttempts = entry.attempts + 1;
      final delayMs = _backoffMsForAttempt(updatedAttempts);
      final nextMs = DateTime.now().millisecondsSinceEpoch + delayMs;
      _outbox[entry.tempId] = entry.copyWith(
        attempts: updatedAttempts,
        nextAttemptAtMs: nextMs,
      );
      _failedTempIds.add(entry.tempId);
      await _saveOutbox();
    } finally {
      _outboxInFlight.remove(entry.tempId);
      if (mounted) setState(() {});
    }
  }

  void _pumpOutbox() {
    if (!mounted) return;
    if (_outbox.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final candidates =
        _outbox.values.where((e) => (e.nextAttemptAtMs ?? 0) <= now).toList()
          ..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));

    for (final entry in candidates) {
      if (_outboxInFlight.contains(entry.tempId)) continue;
      unawaited(_attemptSendOutboxEntry(entry));
      break;
    }
  }

  void _retryTempId(String tempId) {
    final entry = _outbox[tempId];
    if (entry == null) return;
    _outbox[tempId] = entry.copyWith(
      nextAttemptAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _failedTempIds.remove(tempId);
    unawaited(_saveOutbox());
    _pumpOutbox();
    if (mounted) setState(() {});
  }

  Future<String> _uploadBytesWithRetry({
    required Reference storageRef,
    required Uint8List bytes,
    required String contentType,
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final upload = await storageRef
            .putData(bytes, SettableMetadata(contentType: contentType))
            .timeout(_uploadTimeout);
        return await upload.ref.getDownloadURL().timeout(_downloadUrlTimeout);
      } catch (e) {
        lastError = e;
        if (attempt == maxAttempts) break;
        await Future.delayed(
          Duration(milliseconds: 700 * (1 << (attempt - 1))),
        );
      }
    }
    throw lastError ?? Exception('Upload failed');
  }

  static const _emojiPalette = <String>[
    '😀',
    '😊',
    '😉',
    '👍',
    '🙏',
    '🎉',
    '🔥',
    '❤️',
    '👏',
    '🤝',
    '🤔',
    '✅',
  ];

  @override
  void initState() {
    super.initState();
    _trayTabController = TabController(length: 3, vsync: this);
    _gifSearch.addListener(_onGifQueryChanged);
    _text.addListener(_handleTextChanged);
    _scrollController.addListener(_handleScroll);

    Future.microtask(() async {
      await _restoreOutbox();
      _pumpOutbox();
    });
    _outboxPump = Timer.periodic(const Duration(seconds: 6), (_) {
      _pumpOutbox();
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _outboxPump?.cancel();
    _gifDebounce?.cancel();
    _trayTabController.dispose();
    _gifSearch.removeListener(_onGifQueryChanged);
    _gifSearchFocusNode.dispose();
    _text.removeListener(_handleTextChanged);
    // Best-effort: clear typing flag even though ref is no longer usable here.
    unawaited(_clearTypingOnDispose());
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _focusNode.dispose();
    _gifSearch.dispose();
    _text.dispose();
    super.dispose();
  }

  String? get _tenorApiKey {
    final key = (dotenv.env['TENOR_API_KEY'] ?? '').trim();
    return key.isEmpty ? null : key;
  }

  void _toggleTray() {
    setState(() {
      _trayOpen = !_trayOpen;
      _actionsOpen = false;
      _gifError = null;
    });
    if (_trayOpen) {
      _trayTabController.index = 1; // GIFs
      _gifSearch.clear();
      _gifSearchFocusNode.requestFocus();
      unawaited(_loadTrendingGifs());
    } else {
      _gifSearchFocusNode.unfocus();
      _focusNode.requestFocus();
    }
  }

  void _toggleActions() {
    if (_trayOpen) {
      _closeTray();
    }
    setState(() {
      _actionsOpen = !_actionsOpen;
    });
    if (_actionsOpen) {
      _focusNode.unfocus();
      _gifSearchFocusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }

  void _closeActions() {
    if (!_actionsOpen) return;
    setState(() {
      _actionsOpen = false;
    });
  }

  void _closeTray() {
    if (!_trayOpen) return;
    setState(() {
      _trayOpen = false;
      _actionsOpen = false;
      _gifError = null;
    });
    _gifSearchFocusNode.unfocus();
    _focusNode.requestFocus();
  }

  void _onGifQueryChanged() {
    if (!_trayOpen) return;
    if (_trayTabController.index != 1) return; // GIFs tab
    _gifDebounce?.cancel();
    _gifDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final q = _gifSearch.text.trim();
      if (q.isEmpty) {
        unawaited(_loadTrendingGifs());
      } else {
        unawaited(_searchGifs(q));
      }
    });
  }

  void _handleTextChanged() {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;

    _typingTimer?.cancel();
    final isTyping = _text.text.trim().isNotEmpty;
    unawaited(_setTyping(isTyping));
    if (isTyping) {
      _typingTimer = Timer(const Duration(seconds: 2), () {
        unawaited(_setTyping(false));
      });
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final shouldShow = _scrollController.offset > 260;
    if (shouldShow == _showJumpToLatest) return;
    setState(() => _showJumpToLatest = shouldShow);
  }

  void _scrollToLatest() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _startCall(String kind) {
    if (!mounted) return;
    context.push('/chats/thread/${widget.threadId}/call/$kind');
  }

  Future<void> _setTyping(bool typing) async {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;
    final db = ref.read(firestoreProvider);
    await db.collection(FirestorePaths.chatThreads).doc(widget.threadId).set({
      'typing.${user.uid}': typing,
    }, SetOptions(merge: true));
  }

  Future<void> _clearTypingOnDispose() async {
    try {
      await _setTyping(false);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _loadTrendingGifs() async {
    if (!mounted) return;
    setState(() {
      _gifLoading = true;
      _gifError = null;
    });
    try {
      final gifs = await _fetchTenorGifs(query: null);
      if (!mounted) return;
      setState(() {
        _gifItems = gifs;
        _gifLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gifItems = const [];
        _gifLoading = false;
        _gifError = e.toString();
      });
    }
  }

  Future<void> _searchGifs(String query) async {
    if (!mounted) return;
    setState(() {
      _gifLoading = true;
      _gifError = null;
    });
    try {
      final gifs = await _fetchTenorGifs(query: query);
      if (!mounted) return;
      setState(() {
        _gifItems = gifs;
        _gifLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gifItems = const [];
        _gifLoading = false;
        _gifError = e.toString();
      });
    }
  }

  Future<List<_GifItem>> _fetchTenorGifs({required String? query}) async {
    final apiKey = _tenorApiKey;
    if (apiKey == null) {
      throw Exception('TENOR_API_KEY missing in .env');
    }

    final q = (query ?? '').trim();
    final path = q.isEmpty ? '/v2/featured' : '/v2/search';
    final uri = Uri.https('tenor.googleapis.com', path, {
      'key': apiKey,
      'client_key': 'ieee_organizer',
      'limit': '24',
      'contentfilter': 'low',
      if (q.isNotEmpty) 'q': q,
    });

    final resp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Tenor error (${resp.statusCode})');
    }

    final decoded = jsonDecode(resp.body);
    final results = (decoded is Map<String, dynamic>)
        ? (decoded['results'] as List?)
        : null;
    if (results == null) return const [];

    String? urlFor(Map<String, dynamic>? mf, String key) {
      final v = mf?[key];
      if (v is Map<String, dynamic>) {
        final u = v['url'];
        if (u is String && u.isNotEmpty) return u;
      }
      return null;
    }

    final items = <_GifItem>[];
    for (final r in results) {
      if (r is! Map<String, dynamic>) continue;
      final id = (r['id'] ?? '').toString();
      final mf = r['media_formats'] is Map
          ? (r['media_formats'] as Map).cast<String, dynamic>()
          : null;

      final preview =
          urlFor(mf, 'tinygif') ?? urlFor(mf, 'nanogif') ?? urlFor(mf, 'gif');
      final full = urlFor(mf, 'gif') ?? urlFor(mf, 'mediumgif') ?? preview;
      if (id.isEmpty || preview == null || full == null) continue;
      items.add(_GifItem(id: id, previewUrl: preview, fullUrl: full));
    }
    return items;
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(day.year, day.month, day.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('MMM d, y').format(d);
  }

  String? _readStatusForMessage(
    ChatThread? thread,
    DateTime? sentAt,
    String? myUid,
  ) {
    if (thread == null || sentAt == null || myUid == null) return null;
    final reads = thread.memberReads;
    if (reads == null || reads.isEmpty) return null;

    final seenCount = reads.entries
        .where((e) => e.key != myUid && e.value.isAfter(sentAt))
        .length;
    if (seenCount <= 0) return null;
    return seenCount == 1 ? 'Seen' : 'Seen by $seenCount';
  }

  void _bumpSend() {
    setState(() => _sendScale = 0.9);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _sendScale = 1);
    });
  }

  void _setReply(ChatMessage message) {
    setState(() => _replyingTo = message);
    _focusNode.requestFocus();
  }

  void _clearReply() {
    if (!mounted) return;
    setState(() => _replyingTo = null);
  }

  void _viewImage(String url) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  Future<void> _showReactionSheet(
    BuildContext context,
    ChatMessage message,
  ) async {
    const reactions = ['👍', '❤️', '😂', '😮', '😢', '😡'];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: reactions
                  .map(
                    (r) => GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(r),
                      child: Text(r, style: const TextStyle(fontSize: 24)),
                    ),
                  )
                  .toList(),
            ),
          ),
        );
      },
    );

    if (!context.mounted || chosen == null) return;
    String? next;
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user != null) {
      final current = message.reactions?[user.uid];
      next = current == chosen ? null : chosen;
      await _setReaction(message.id, next, user.uid);
    }
    if (!context.mounted) return;
    final preview = message.text.isNotEmpty ? ' "${message.text}"' : '';
    final status = next == null ? 'removed' : 'added';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Reaction $status$preview')));
  }

  Future<void> _showMessageActions(
    BuildContext context,
    ChatMessage message,
    bool mine,
  ) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.of(ctx).pop('reply'),
              ),
              ListTile(
                leading: const Icon(Icons.emoji_emotions_outlined),
                title: const Text('Add reaction'),
                onTap: () => Navigator.of(ctx).pop('react'),
              ),
              if (mine && !(message.deleted))
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit'),
                  onTap: () => Navigator.of(ctx).pop('edit'),
                ),
              if (mine)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete'),
                  onTap: () => Navigator.of(ctx).pop('delete'),
                ),
            ],
          ),
        );
      },
    );

    if (choice == null) return;
    if (!context.mounted) return;
    switch (choice) {
      case 'reply':
        _setReply(message);
        break;
      case 'react':
        await _showReactionSheet(context, message);
        break;
      case 'edit':
        await _editMessage(message);
        break;
      case 'delete':
        await _deleteMessage(message);
        break;
    }
  }

  Future<void> _editMessage(ChatMessage message) async {
    if (message.deleted) return;
    final controller = TextEditingController(text: message.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Edit message'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(hintText: 'Update your message'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (newText == null || newText.isEmpty || newText == message.text) return;
    final db = ref.read(firestoreProvider);
    await db
        .collection(FirestorePaths.threadMessages(widget.threadId))
        .doc(message.id)
        .set({'text': newText, 'edited': true}, SetOptions(merge: true));
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final db = ref.read(firestoreProvider);
    await db
        .collection(FirestorePaths.threadMessages(widget.threadId))
        .doc(message.id)
        .set({
          'text': '',
          'imageUrl': null,
          'fileUrl': null,
          'fileName': null,
          'fileSize': null,
          'audioUrl': null,
          'audioDurationSec': null,
          'deleted': true,
        }, SetOptions(merge: true));
  }

  Future<void> _copyLink(String? url, String label) async {
    if (url == null || url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label link copied')));
  }

  String _formatSize(int? size) {
    if (size == null || size <= 0) return '';
    if (size < 1024) return '${size}B';
    final kb = size / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _contentTypeForExtension(String? ext, {bool audio = false}) {
    final normalized = ext?.toLowerCase();
    if (audio) {
      switch (normalized) {
        case 'wav':
          return 'audio/wav';
        case 'aac':
          return 'audio/aac';
        case 'm4a':
          return 'audio/mp4';
        default:
          return 'audio/mpeg';
      }
    }

    switch (normalized) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'csv':
        return 'text/csv';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _setReaction(
    String messageId,
    String? reaction,
    String uid,
  ) async {
    final db = ref.read(firestoreProvider);
    final path = 'reactions.$uid';
    final payload = reaction == null
        ? {path: FieldValue.delete()}
        : {path: reaction};
    await db
        .collection(FirestorePaths.threadMessages(widget.threadId))
        .doc(messageId)
        .set(payload, SetOptions(merge: true));
  }

  Future<void> _markThreadRead(DateTime? newestMessageAt) async {
    if (newestMessageAt == null) return;
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;
    final db = ref.read(firestoreProvider);
    await db.collection(FirestorePaths.chatThreads).doc(widget.threadId).set({
      'memberReads': {user.uid: FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    await _sendMessageInternal(text: text, imageUrl: null);
  }

  Future<void> _sendLike() async {
    await _sendMessageInternal(text: '👍', imageUrl: null);
  }

  void _insertSnippet(String value) {
    final selection = _text.selection;
    final baseText = _text.text;
    final start = selection.start >= 0 ? selection.start : baseText.length;
    final end = selection.end >= 0 ? selection.end : baseText.length;
    final newText = baseText.replaceRange(start, end, value);
    _text.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
    _focusNode.requestFocus();
  }

  Future<void> _openEmojiPicker() async {
    final context = this.context;
    final emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: _emojiPalette.length,
            itemBuilder: (_, i) {
              final e = _emojiPalette[i];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(ctx).pop(e),
                child: Center(
                  child: Text(e, style: const TextStyle(fontSize: 24)),
                ),
              );
            },
          ),
        );
      },
    );

    if (emoji != null) {
      _insertSnippet(emoji);
    }
  }

  Future<void> _sendImageMessage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 75,
    );
    if (file == null) return;
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null || _sending) return;
    setState(() => _sending = true);
    try {
      final bytes = await file.readAsBytes();
      final storageRef = FirebaseStorage.instance.ref().child(
        'message_media/${widget.threadId}/${const Uuid().v4()}.jpg',
      );
      final url = await _uploadBytesWithRetry(
        storageRef: storageRef,
        bytes: bytes,
        contentType: 'image/jpeg',
      );
      await _sendMessageInternal(text: '', imageUrl: url, alreadySending: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendFileAttachment() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read file bytes')),
        );
      }
      return;
    }
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null || _sending) return;
    setState(() => _sending = true);
    try {
      final storageRef = FirebaseStorage.instance.ref().child(
        'message_files/${widget.threadId}/${const Uuid().v4()}_${picked.name}',
      );
      final url = await _uploadBytesWithRetry(
        storageRef: storageRef,
        bytes: bytes,
        contentType: _contentTypeForExtension(picked.extension),
      );
      await _sendMessageInternal(
        text: picked.name,
        imageUrl: null,
        fileUrl: url,
        fileName: picked.name,
        fileSize: picked.size,
        alreadySending: true,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendVoiceNote() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: const ['m4a', 'aac', 'wav', 'mp3'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read audio bytes')),
        );
      }
      return;
    }
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null || _sending) return;
    setState(() => _sending = true);
    try {
      final storageRef = FirebaseStorage.instance.ref().child(
        'voice_notes/${widget.threadId}/${const Uuid().v4()}_${picked.name}',
      );
      final url = await _uploadBytesWithRetry(
        storageRef: storageRef,
        bytes: bytes,
        contentType: _contentTypeForExtension(picked.extension, audio: true),
      );
      await _sendMessageInternal(
        text: 'Voice note',
        imageUrl: null,
        audioUrl: url,
        audioDurationSec: null,
        fileName: picked.name,
        fileSize: picked.size,
        alreadySending: true,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendMessageInternal({
    required String text,
    String? imageUrl,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? audioUrl,
    int? audioDurationSec,
    bool alreadySending = false,
  }) async {
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;
    if (_sending && !alreadySending) return;
    if (!alreadySending) setState(() => _sending = true);
    final reply = _replyingTo;

    try {
      await _enqueueOutboxAndOptimistic(
        text: text,
        imageUrl: imageUrl,
        fileUrl: fileUrl,
        fileName: fileName,
        fileSize: fileSize,
        audioUrl: audioUrl,
        audioDurationSec: audioDurationSec,
        reply: reply,
      );
      _text.clear();
      _clearReply();
      await _setTyping(false);
      _pumpOutbox();
    } finally {
      if (mounted && !alreadySending) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final threadAsync = ref.watch(threadProvider(widget.threadId));
    final messagesAsync = ref.watch(
      threadMessagesControllerProvider(widget.threadId),
    );
    final user = ref.watch(firebaseAuthProvider).currentUser;
    final myUid = user?.uid;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    ref.listen<AsyncValue<ThreadMessagesState>>(
      threadMessagesControllerProvider(widget.threadId),
      (prev, next) {
        next.whenData((state) {
          final newest = state.messages.isNotEmpty
              ? state.messages.first.sentAt
              : null;
          _markThreadRead(newest);
        });
      },
    );

    final appBar = widget.embedded
        ? null
        : AppBar(
            titleSpacing: 0,
            title: threadAsync.maybeWhen(
              data: (t) => t == null
                  ? const Text('Chat')
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => context.push(
                        '/chats/thread/${widget.threadId}/profile',
                      ),
                      child: _ThreadHeader(
                        thread: t,
                        myUid: myUid,
                        subtitleOverride: 'Messenger',
                      ),
                    ),
              orElse: () => const Text('Chat'),
            ),
            actions: [
              threadAsync.maybeWhen(
                data: (t) {
                  if (t == null) return const SizedBox.shrink();
                  return Row(
                    children: [
                      IconButton(
                        tooltip: 'Audio call',
                        icon: const Icon(Icons.call_outlined),
                        onPressed: () => _startCall('audio'),
                      ),
                      IconButton(
                        tooltip: 'Video call',
                        icon: const Icon(Icons.videocam_outlined),
                        onPressed: () => _startCall('video'),
                      ),
                    ],
                  );
                },
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          );

    final scaffold = Scaffold(
      backgroundColor: cs.surface,
      appBar: appBar,

      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: messagesAsync.when(
                  data: (state) {
                    final messages = state.messages;
                    if (messages.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
                          child: threadAsync.maybeWhen(
                            data: (t) => t == null
                                ? const SizedBox.shrink()
                                : _ChatIntro(thread: t, myUid: myUid),
                            orElse: () => const SizedBox.shrink(),
                          ),
                        ),
                      );
                    }

                    final grouped = <DateTime, List<ChatMessage>>{};
                    for (final m in messages) {
                      final day =
                          m.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                      final key = DateTime(day.year, day.month, day.day);
                      grouped.putIfAbsent(key, () => []).add(m);
                    }
                    final dayKeys = grouped.keys.toList()
                      ..sort((a, b) => b.compareTo(a));
                    final totalItems = dayKeys.fold<int>(0, (acc, k) {
                      return acc + 1 + grouped[k]!.length;
                    });
                    final myLastRead = threadAsync.value?.memberReads?[myUid];
                    ChatMessage? latestMine;
                    for (final m in messages) {
                      if (myUid != null && m.senderUid == myUid) {
                        latestMine = m;
                        break;
                      }
                    }
                    String? firstUnreadId;
                    if (myLastRead != null) {
                      for (final m in messages.reversed) {
                        final mineCandidate =
                            myUid != null && m.senderUid == myUid;
                        if (!mineCandidate &&
                            m.sentAt != null &&
                            m.sentAt!.isAfter(myLastRead)) {
                          firstUnreadId = m.id;
                          break;
                        }
                      }
                    }

                    final extraRow = state.isLoadingMore ? 1 : 0;
                    final bottomPad =
                        (_trayOpen
                            ? _composerPadOpen
                            : (_actionsOpen
                                  ? _composerPadActions
                                  : _composerPadClosed)) +
                        MediaQuery.paddingOf(context).bottom;
                    return ListView.builder(
                      reverse: true,
                      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
                      controller: _scrollController,
                      itemCount: totalItems + extraRow,
                      itemBuilder: (context, idx) {
                        if (state.isLoadingMore && idx == totalItems) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        var cursor = 0;
                        for (final key in dayKeys) {
                          final list = grouped[key]!;
                          if (idx == cursor) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Divider(thickness: 0.6),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _dayLabel(key),
                                    style: theme.textTheme.labelMedium,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Divider(thickness: 0.6),
                                  ),
                                ],
                              ),
                            );
                          }
                          cursor++;
                          if (idx < cursor + list.length) {
                            final listIndex = idx - cursor;
                            final m = list[listIndex];
                            final prev = listIndex > 0
                                ? list[listIndex - 1]
                                : null;
                            final nextMsg = listIndex + 1 < list.length
                                ? list[listIndex + 1]
                                : null;
                            bool closeTo(ChatMessage? a, ChatMessage? b) {
                              if (a?.sentAt == null || b?.sentAt == null) {
                                return false;
                              }
                              return a!.sentAt!.difference(b!.sentAt!).abs() <=
                                  const Duration(minutes: 5);
                            }

                            final mine = myUid != null && m.senderUid == myUid;
                            final continuesFromPrev =
                                prev != null &&
                                prev.senderUid == m.senderUid &&
                                closeTo(m, prev);
                            final continuesToNext =
                                nextMsg != null &&
                                nextMsg.senderUid == m.senderUid &&
                                closeTo(m, nextMsg);
                            final topPadding = continuesFromPrev ? 2.0 : 8.0;
                            final showAvatar = !mine && !continuesToNext;
                            final showTail = !continuesToNext;

                            final sentAt = m.sentAt;
                            final profileAsync = ref.watch(
                              userProfileProvider(m.senderUid),
                            );
                            final senderName = profileAsync.maybeWhen(
                              data: (p) => (p?.displayName.isNotEmpty ?? false)
                                  ? p!.displayName
                                  : (mine ? 'You' : 'Member'),
                              orElse: () => mine ? 'You' : 'Member',
                            );
                            final avatarUrl = profileAsync.maybeWhen(
                              data: (p) => p?.photoUrl,
                              orElse: () => null,
                            );
                            final timeLabel = sentAt == null
                                ? ''
                                : DateFormat('h:mm a').format(sentAt.toLocal());
                            final readByOthers = _readStatusForMessage(
                              threadAsync.value,
                              m.sentAt,
                              myUid,
                            );
                            final bubbleColor = mine
                                ? cs.primary
                                : cs.surfaceContainerHighest;
                            final bubbleTextColor = mine
                                ? cs.onPrimary
                                : cs.onSurface;
                            final reactions = m.reactions ?? const {};
                            final deleted = m.deleted;
                            final edited = m.edited;
                            final fileUrl = m.fileUrl;
                            final fileName = m.fileName;
                            final fileSize = m.fileSize;
                            final audioUrl = m.audioUrl;
                            final replyToId = m.replyToMessageId;
                            final replyToText = m.replyToText ?? '';
                            final replyToSenderUid = m.replyToSenderUid;
                            String replySenderName = replyToSenderUid == null
                                ? 'Message'
                                : (replyToSenderUid == myUid
                                      ? 'You'
                                      : 'Member');
                            if (replyToSenderUid != null) {
                              final replyProfile = ref.watch(
                                userProfileProvider(replyToSenderUid),
                              );
                              replySenderName = replyProfile.maybeWhen(
                                data: (p) =>
                                    (p?.displayName.isNotEmpty ?? false)
                                    ? p!.displayName
                                    : replySenderName,
                                orElse: () => replySenderName,
                              );
                            }
                            final reactionCounts = <String, int>{};
                            for (final r in reactions.values) {
                              if (r.isEmpty) continue;
                              reactionCounts[r] = (reactionCounts[r] ?? 0) + 1;
                            }
                            final reactionIcons = reactionCounts.keys
                                .take(3)
                                .toList();
                            final reactionTotal = reactionCounts.values
                                .fold<int>(0, (a, b) => a + b);
                            final showNewDivider =
                                firstUnreadId != null && firstUnreadId == m.id;
                            final showSenderLabel =
                                !mine &&
                                !continuesFromPrev &&
                                (threadAsync.value?.isGroup ?? false);

                            return Column(
                              crossAxisAlignment: mine
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (showNewDivider)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: const [
                                        Expanded(
                                          child: Divider(thickness: 0.6),
                                        ),
                                        SizedBox(width: 8),
                                        Text('New'),
                                        SizedBox(width: 8),
                                        Expanded(
                                          child: Divider(thickness: 0.6),
                                        ),
                                      ],
                                    ),
                                  ),
                                Align(
                                  alignment: mine
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Padding(
                                    padding: EdgeInsets.only(top: topPadding),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        if (!mine)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: AnimatedOpacity(
                                              duration: const Duration(
                                                milliseconds: 180,
                                              ),
                                              opacity: showAvatar ? 1 : 0,
                                              child: showAvatar
                                                  ? CircleAvatar(
                                                      radius: 16,
                                                      backgroundImage:
                                                          (avatarUrl == null ||
                                                              avatarUrl.isEmpty)
                                                          ? null
                                                          : NetworkImage(
                                                              avatarUrl,
                                                            ),
                                                      child:
                                                          (avatarUrl == null ||
                                                              avatarUrl.isEmpty)
                                                          ? const Icon(
                                                              Icons.person,
                                                              size: 16,
                                                            )
                                                          : null,
                                                    )
                                                  : const SizedBox(
                                                      width: 32,
                                                      height: 32,
                                                    ),
                                            ),
                                          ),
                                        Flexible(
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 4,
                                            ),
                                            child: Material(
                                              type: MaterialType.transparency,
                                              child: InkWell(
                                                mouseCursor:
                                                    SystemMouseCursors.click,
                                                hoverColor: cs
                                                    .surfaceContainerHighest
                                                    .withValues(alpha: 0.25),
                                                onLongPress: () =>
                                                    _showMessageActions(
                                                      context,
                                                      m,
                                                      mine,
                                                    ),
                                                child: Stack(
                                                  clipBehavior: Clip.none,
                                                  children: [
                                                    if (showTail)
                                                      Positioned(
                                                        bottom: 8,
                                                        left: mine ? null : -6,
                                                        right: mine ? -6 : null,
                                                        child: _BubbleTail(
                                                          color: bubbleColor,
                                                          isMine: mine,
                                                        ),
                                                      ),
                                                    DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        color: bubbleColor,
                                                        border: mine
                                                            ? null
                                                            : Border.all(
                                                                color: cs
                                                                    .outlineVariant
                                                                    .withValues(
                                                                      alpha:
                                                                          0.5,
                                                                    ),
                                                              ),
                                                        borderRadius: BorderRadius.only(
                                                          topLeft:
                                                              Radius.circular(
                                                                mine ? 18 : 14,
                                                              ),
                                                          topRight:
                                                              Radius.circular(
                                                                mine ? 14 : 18,
                                                              ),
                                                          bottomLeft:
                                                              Radius.circular(
                                                                mine
                                                                    ? 18
                                                                    : (continuesToNext
                                                                          ? 8
                                                                          : 18),
                                                              ),
                                                          bottomRight:
                                                              Radius.circular(
                                                                mine
                                                                    ? (continuesToNext
                                                                          ? 8
                                                                          : 18)
                                                                    : 18,
                                                              ),
                                                        ),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color: cs.shadow
                                                                .withValues(
                                                                  alpha: mine
                                                                      ? 0.25
                                                                      : 0.12,
                                                                ),
                                                            blurRadius: mine
                                                                ? 12
                                                                : 8,
                                                            offset:
                                                                const Offset(
                                                                  0,
                                                                  2,
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.fromLTRB(
                                                              12,
                                                              10,
                                                              12,
                                                              8,
                                                            ),
                                                        child: ConstrainedBox(
                                                          constraints:
                                                              BoxConstraints(
                                                                maxWidth:
                                                                    MediaQuery.sizeOf(
                                                                      context,
                                                                    ).width *
                                                                    0.78,
                                                              ),
                                                          child: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              if (showSenderLabel)
                                                                Padding(
                                                                  padding:
                                                                      const EdgeInsets.only(
                                                                        bottom:
                                                                            4,
                                                                      ),
                                                                  child: Text(
                                                                    senderName,
                                                                    style: theme
                                                                        .textTheme
                                                                        .labelMedium
                                                                        ?.copyWith(
                                                                          color: bubbleTextColor.withValues(
                                                                            alpha:
                                                                                0.9,
                                                                          ),
                                                                        ),
                                                                  ),
                                                                ),
                                                              if (replyToId !=
                                                                  null)
                                                                Container(
                                                                  margin:
                                                                      const EdgeInsets.only(
                                                                        bottom:
                                                                            6,
                                                                      ),
                                                                  padding:
                                                                      const EdgeInsets.all(
                                                                        10,
                                                                      ),
                                                                  decoration: BoxDecoration(
                                                                    color: cs
                                                                        .surface,
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          12,
                                                                        ),
                                                                    border: Border.all(
                                                                      color: cs
                                                                          .outlineVariant
                                                                          .withValues(
                                                                            alpha:
                                                                                0.6,
                                                                          ),
                                                                    ),
                                                                  ),
                                                                  child: Column(
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .start,
                                                                    mainAxisSize:
                                                                        MainAxisSize
                                                                            .min,
                                                                    children: [
                                                                      Text(
                                                                        replySenderName,
                                                                        style: theme
                                                                            .textTheme
                                                                            .labelSmall,
                                                                      ),
                                                                      const SizedBox(
                                                                        height:
                                                                            2,
                                                                      ),
                                                                      Text(
                                                                        replyToText.isNotEmpty
                                                                            ? replyToText
                                                                            : 'Attachment',
                                                                        maxLines:
                                                                            2,
                                                                        overflow:
                                                                            TextOverflow.ellipsis,
                                                                        style: theme
                                                                            .textTheme
                                                                            .bodySmall,
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              if (deleted)
                                                                Padding(
                                                                  padding:
                                                                      const EdgeInsets.only(
                                                                        top: 2,
                                                                        bottom:
                                                                            4,
                                                                      ),
                                                                  child: Text(
                                                                    'Message deleted',
                                                                    style: theme
                                                                        .textTheme
                                                                        .bodySmall
                                                                        ?.copyWith(
                                                                          color:
                                                                              cs.onSurfaceVariant,
                                                                        ),
                                                                  ),
                                                                ),
                                                              if (!deleted &&
                                                                  fileUrl !=
                                                                      null)
                                                                InkWell(
                                                                  mouseCursor:
                                                                      SystemMouseCursors
                                                                          .click,
                                                                  onTap: () =>
                                                                      _copyLink(
                                                                        fileUrl,
                                                                        'File',
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        12,
                                                                      ),
                                                                  child: Container(
                                                                    margin:
                                                                        const EdgeInsets.only(
                                                                          bottom:
                                                                              6,
                                                                        ),
                                                                    padding:
                                                                        const EdgeInsets.all(
                                                                          10,
                                                                        ),
                                                                    decoration: BoxDecoration(
                                                                      color: cs
                                                                          .surface,
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                            12,
                                                                          ),
                                                                      border: Border.all(
                                                                        color: cs
                                                                            .outlineVariant
                                                                            .withValues(
                                                                              alpha: 0.6,
                                                                            ),
                                                                      ),
                                                                    ),
                                                                    child: Row(
                                                                      children: [
                                                                        const Icon(
                                                                          Icons
                                                                              .attach_file,
                                                                        ),
                                                                        const SizedBox(
                                                                          width:
                                                                              8,
                                                                        ),
                                                                        Expanded(
                                                                          child: Text(
                                                                            fileName ??
                                                                                'Attachment',
                                                                            maxLines:
                                                                                1,
                                                                            overflow:
                                                                                TextOverflow.ellipsis,
                                                                          ),
                                                                        ),
                                                                        if (fileSize !=
                                                                            null)
                                                                          Text(
                                                                            _formatSize(
                                                                              fileSize,
                                                                            ),
                                                                            style:
                                                                                theme.textTheme.labelSmall,
                                                                          ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ),
                                                              if (!deleted &&
                                                                  audioUrl !=
                                                                      null)
                                                                InkWell(
                                                                  mouseCursor:
                                                                      SystemMouseCursors
                                                                          .click,
                                                                  onTap: () =>
                                                                      _copyLink(
                                                                        audioUrl,
                                                                        'Voice note',
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        12,
                                                                      ),
                                                                  child: Container(
                                                                    margin:
                                                                        const EdgeInsets.only(
                                                                          bottom:
                                                                              6,
                                                                        ),
                                                                    padding:
                                                                        const EdgeInsets.all(
                                                                          10,
                                                                        ),
                                                                    decoration: BoxDecoration(
                                                                      color: cs
                                                                          .surface,
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                            12,
                                                                          ),
                                                                      border: Border.all(
                                                                        color: cs
                                                                            .outlineVariant
                                                                            .withValues(
                                                                              alpha: 0.6,
                                                                            ),
                                                                      ),
                                                                    ),
                                                                    child: Row(
                                                                      children: [
                                                                        const Icon(
                                                                          Icons
                                                                              .graphic_eq,
                                                                        ),
                                                                        const SizedBox(
                                                                          width:
                                                                              8,
                                                                        ),
                                                                        Expanded(
                                                                          child: Text(
                                                                            fileName ??
                                                                                'Voice note',
                                                                            maxLines:
                                                                                1,
                                                                            overflow:
                                                                                TextOverflow.ellipsis,
                                                                          ),
                                                                        ),
                                                                        if (fileSize !=
                                                                            null)
                                                                          Text(
                                                                            _formatSize(
                                                                              fileSize,
                                                                            ),
                                                                            style:
                                                                                theme.textTheme.labelSmall,
                                                                          ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ),
                                                              if (m.imageUrl !=
                                                                  null)
                                                                Padding(
                                                                  padding:
                                                                      const EdgeInsets.only(
                                                                        bottom:
                                                                            6,
                                                                      ),
                                                                  child: GestureDetector(
                                                                    onTap: () =>
                                                                        _viewImage(
                                                                          m.imageUrl!,
                                                                        ),
                                                                    child: ClipRRect(
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                            12,
                                                                          ),
                                                                      child: Image.network(
                                                                        m.imageUrl!,
                                                                        width:
                                                                            260,
                                                                        fit: BoxFit
                                                                            .cover,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              if (!deleted &&
                                                                  m
                                                                      .text
                                                                      .isNotEmpty)
                                                                Text(
                                                                  m.text,
                                                                  style: TextStyle(
                                                                    color:
                                                                        bubbleTextColor,
                                                                    height: 1.3,
                                                                  ),
                                                                ),
                                                              if (edited &&
                                                                  !deleted)
                                                                Padding(
                                                                  padding:
                                                                      const EdgeInsets.only(
                                                                        top: 4,
                                                                      ),
                                                                  child: Text(
                                                                    'Edited',
                                                                    style: theme
                                                                        .textTheme
                                                                        .labelSmall,
                                                                  ),
                                                                ),
                                                              if (timeLabel
                                                                  .isNotEmpty) ...[
                                                                const SizedBox(
                                                                  height: 6,
                                                                ),
                                                                Align(
                                                                  alignment:
                                                                      Alignment
                                                                          .centerRight,
                                                                  child: _StatusTicks(
                                                                    timeLabel:
                                                                        timeLabel,
                                                                    readByLabel:
                                                                        readByOthers,
                                                                    pending: m
                                                                        .pending,
                                                                    failed:
                                                                        m.pending &&
                                                                        _failedTempIds
                                                                            .contains(
                                                                              m.id,
                                                                            ),
                                                                    onRetry:
                                                                        m.pending &&
                                                                            _failedTempIds.contains(
                                                                              m.id,
                                                                            )
                                                                        ? () => _retryTempId(
                                                                            m.id,
                                                                          )
                                                                        : null,
                                                                    color: bubbleTextColor
                                                                        .withValues(
                                                                          alpha:
                                                                              0.8,
                                                                        ),
                                                                  ),
                                                                ),
                                                              ],
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    if (!deleted &&
                                                        reactionTotal > 0)
                                                      Positioned(
                                                        right: mine ? 4 : null,
                                                        left: mine ? null : 4,
                                                        bottom: -12,
                                                        child: DecoratedBox(
                                                          decoration: BoxDecoration(
                                                            color: cs.surface,
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  16,
                                                                ),
                                                            border: Border.all(
                                                              color: cs
                                                                  .outlineVariant
                                                                  .withValues(
                                                                    alpha: 0.7,
                                                                  ),
                                                            ),
                                                          ),
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 6,
                                                                  vertical: 2,
                                                                ),
                                                            child: Row(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                ...reactionIcons.map(
                                                                  (
                                                                    icon,
                                                                  ) => Padding(
                                                                    padding:
                                                                        const EdgeInsets.symmetric(
                                                                          horizontal:
                                                                              2,
                                                                        ),
                                                                    child: Text(
                                                                      icon,
                                                                      style: const TextStyle(
                                                                        fontSize:
                                                                            14,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  width: 2,
                                                                ),
                                                                Text(
                                                                  reactionTotal
                                                                      .toString(),
                                                                  style: theme
                                                                      .textTheme
                                                                      .labelSmall,
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (!deleted && reactionTotal > 0)
                                  const SizedBox(height: 16),
                                if (mine &&
                                    latestMine != null &&
                                    latestMine.id == m.id &&
                                    sentAt != null)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 48,
                                      right: 12,
                                      top: 6,
                                    ),
                                    child: _ReadAvatars(
                                      thread: threadAsync.value,
                                      myUid: myUid,
                                      sentAt: sentAt,
                                    ),
                                  ),
                              ],
                            );
                          }
                          cursor += list.length;
                        }
                        return const SizedBox.shrink();
                      },
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 40),
                          const SizedBox(height: 12),
                          const Text('Could not load messages.'),
                          const SizedBox(height: 8),
                          SelectableText(e.toString()),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_showJumpToLatest)
            Positioned(
              right: 16,
              bottom: 120,
              child: FloatingActionButton.small(
                heroTag: 'jump-latest',
                onPressed: _scrollToLatest,
                child: const Icon(Icons.arrow_downward_rounded),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(32),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _text,
                    builder: (context, value, _) {
                      final canSend =
                          myUid != null &&
                          !_sending &&
                          value.text.trim().isNotEmpty;
                      final canLike =
                          myUid != null &&
                          !_sending &&
                          value.text.trim().isEmpty;

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_replyingTo != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: cs.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.reply, size: 20),
                                  title: Text(
                                    _replyingTo!.text.isNotEmpty
                                        ? _replyingTo!.text
                                        : 'Attachment',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    _replyingTo!.senderUid == myUid
                                        ? 'You'
                                        : 'Replying',
                                    maxLines: 1,
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: _clearReply,
                                  ),
                                ),
                              ),
                            ),
                          _TypingIndicator(
                            threadAsync: threadAsync,
                            myUid: myUid,
                          ),
                          if (_trayOpen)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                              child: SizedBox(
                                height: _trayHeight,
                                child: _MediaTray(
                                  tabController: _trayTabController,
                                  theme: theme,
                                  colorScheme: cs,
                                  searchController: _gifSearch,
                                  searchFocusNode: _gifSearchFocusNode,
                                  loading: _gifLoading,
                                  error: _gifError,
                                  gifs: _gifItems,
                                  emojiPalette: _emojiPalette,
                                  onClose: _closeTray,
                                  onPickGif: (url) {
                                    unawaited(
                                      _sendMessageInternal(
                                        text: '',
                                        imageUrl: url,
                                      ),
                                    );
                                    _closeTray();
                                  },
                                  onPickEmoji: (e) {
                                    _insertSnippet(e);
                                    _closeTray();
                                  },
                                ),
                              ),
                            ),
                          if (_actionsOpen && !_trayOpen)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                              child: Row(
                                children: [
                                  IconButton(
                                    tooltip: 'GIFs',
                                    onPressed: (_sending || myUid == null)
                                        ? null
                                        : () {
                                            _closeActions();
                                            _toggleTray();
                                          },
                                    icon: const Icon(Icons.gif_box_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Image',
                                    onPressed: (_sending || myUid == null)
                                        ? null
                                        : () {
                                            _closeActions();
                                            unawaited(_sendImageMessage());
                                          },
                                    icon: const Icon(Icons.photo_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'File',
                                    onPressed: (_sending || myUid == null)
                                        ? null
                                        : () {
                                            _closeActions();
                                            unawaited(_sendFileAttachment());
                                          },
                                    icon: const Icon(Icons.attach_file),
                                  ),
                                  IconButton(
                                    tooltip: 'Voice note',
                                    onPressed: (_sending || myUid == null)
                                        ? null
                                        : () {
                                            _closeActions();
                                            unawaited(_sendVoiceNote());
                                          },
                                    icon: const Icon(Icons.mic_outlined),
                                  ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: 'More',
                                  onPressed: (_sending || myUid == null)
                                      ? null
                                      : _toggleActions,
                                  icon: Icon(
                                    _actionsOpen
                                        ? Icons.add_circle
                                        : Icons.add_circle_outline,
                                    color: cs.primary,
                                  ),
                                ),
                                Expanded(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: cs.surface,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: cs.outlineVariant.withValues(
                                          alpha: 0.35,
                                        ),
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 2,
                                    ),
                                    child: TextField(
                                      controller: _text,
                                      focusNode: _focusNode,
                                      enabled: !_sending && myUid != null,
                                      minLines: 1,
                                      maxLines: 5,
                                      textInputAction: TextInputAction.newline,
                                      decoration: InputDecoration(
                                        hintText: myUid == null
                                            ? 'Sign in to chat'
                                            : 'Aa',
                                        hintStyle: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                            ),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                      ),
                                      onTap: _closeActions,
                                      onSubmitted: (_) =>
                                          canSend ? _send() : null,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Emoji',
                                  onPressed: (_sending || myUid == null)
                                      ? null
                                      : () {
                                          _closeActions();
                                          _openEmojiPicker();
                                        },
                                  icon: const Icon(
                                    Icons.emoji_emotions_outlined,
                                  ),
                                ),
                                if (canSend)
                                  InkWell(
                                    onTap: () {
                                      _bumpSend();
                                      _send();
                                    },
                                    borderRadius: BorderRadius.circular(22),
                                    child: AnimatedScale(
                                      scale: _sendScale,
                                      duration: const Duration(
                                        milliseconds: 140,
                                      ),
                                      curve: Curves.easeOut,
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 150,
                                        ),
                                        height: 40,
                                        width: 40,
                                        decoration: BoxDecoration(
                                          color: cs.primary,
                                          shape: BoxShape.circle,
                                        ),
                                        child: _sending
                                            ? const Padding(
                                                padding: EdgeInsets.all(10),
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation(
                                                        Colors.white,
                                                      ),
                                                ),
                                              )
                                            : const Icon(
                                                Icons.send_rounded,
                                                color: Colors.white,
                                              ),
                                      ),
                                    ),
                                  )
                                else
                                  IconButton(
                                    tooltip: 'Like',
                                    onPressed: canLike ? _sendLike : null,
                                    icon: Icon(
                                      Icons.thumb_up_alt,
                                      color: cs.primary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return scaffold;
  }
}

class _StatusTicks extends StatelessWidget {
  const _StatusTicks({
    required this.timeLabel,
    required this.readByLabel,
    required this.pending,
    required this.failed,
    required this.onRetry,
    required this.color,
  });

  final String timeLabel;
  final String? readByLabel;
  final bool pending;
  final bool failed;
  final VoidCallback? onRetry;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: color);

    final showRead = (readByLabel ?? '').trim().isNotEmpty;

    IconData icon;
    Color iconColor;
    if (failed) {
      icon = Icons.error_outline;
      iconColor = cs.error;
    } else if (pending) {
      icon = Icons.schedule;
      iconColor = color;
    } else {
      icon = showRead ? Icons.done_all : Icons.done;
      iconColor = color;
    }

    final iconWidget = Icon(icon, size: 14, color: iconColor);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(timeLabel, style: style),
        if (showRead) ...[
          const SizedBox(width: 6),
          Text(readByLabel!, style: style),
        ],
        const SizedBox(width: 6),
        if (failed && onRetry != null)
          InkResponse(onTap: onRetry, radius: 18, child: iconWidget)
        else
          iconWidget,
      ],
    );
  }
}

class _BubbleTail extends StatelessWidget {
  const _BubbleTail({required this.color, required this.isMine});

  final Color color;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(12, 12),
      painter: _BubbleTailPainter(color: color, isMine: isMine),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  const _BubbleTailPainter({required this.color, required this.isMine});

  final Color color;
  final bool isMine;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    if (isMine) {
      path.moveTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.lineTo(size.width, 0);
    } else {
      path.moveTo(0, size.height);
      path.lineTo(size.width, size.height);
      path.lineTo(0, 0);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ThreadHeader extends ConsumerWidget {
  const _ThreadHeader({
    required this.thread,
    required this.myUid,
    this.subtitleOverride,
  });

  final ChatThread thread;
  final String? myUid;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final otherUid = (!thread.isGroup && myUid != null)
        ? thread.memberUids.firstWhere((id) => id != myUid, orElse: () => '')
        : '';

    final AsyncValue<UserProfile?> profileAsync = otherUid.isNotEmpty
        ? ref.watch(userProfileProvider(otherUid))
        : const AsyncValue<UserProfile?>.data(null);

    return Row(
      children: [
        _ThreadAvatar(thread: thread, profileAsync: profileAsync),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _displayName(thread, profileAsync),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              _subtitle(thread, profileAsync, context),
            ],
          ),
        ),
      ],
    );
  }

  String _displayName(ChatThread t, AsyncValue<UserProfile?> profileAsync) {
    if (t.isGroup) return t.name ?? 'Group chat';
    return profileAsync.when(
      data: (p) =>
          p?.displayName.isNotEmpty == true ? p!.displayName : 'Direct message',
      loading: () => 'Loading...',
      error: (error, stackTrace) => 'Direct message',
    );
  }

  Widget _subtitle(
    ChatThread t,
    AsyncValue<UserProfile?> profileAsync,
    BuildContext context,
  ) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    if (subtitleOverride != null && subtitleOverride!.isNotEmpty) {
      return Text(subtitleOverride!, style: style);
    }

    if (t.isGroup && t.memberUids.isNotEmpty) {
      return Text('${t.memberUids.length} members', style: style);
    }

    return profileAsync.when(
      data: (p) {
        if (p == null) return const SizedBox.shrink();
        if (p.online == true) {
          return Text('Online', style: style);
        }
        if (p.lastSeen != null) {
          final dt = p.lastSeen!;
          final now = DateTime.now();
          final diff = now.difference(dt);
          final label = diff.inMinutes < 60
              ? '${diff.inMinutes}m ago'
              : diff.inHours < 24
              ? '${diff.inHours}h ago'
              : DateFormat('MMM d, h:mm a').format(dt);
          return Text('Last seen $label', style: style);
        }
        return const SizedBox.shrink();
      },
      loading: () => const SizedBox.shrink(),
      error: (error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

class _ChatIntro extends ConsumerWidget {
  const _ChatIntro({required this.thread, required this.myUid});

  final ChatThread thread;
  final String? myUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    final otherUid = (!thread.isGroup && myUid != null)
        ? thread.memberUids.firstWhere((id) => id != myUid, orElse: () => '')
        : '';

    final AsyncValue<UserProfile?> profileAsync = otherUid.isNotEmpty
        ? ref.watch(userProfileProvider(otherUid))
        : const AsyncValue<UserProfile?>.data(null);

    final title = thread.isGroup
        ? (thread.name ?? 'Group chat')
        : profileAsync.maybeWhen(
            data: (p) => (p?.displayName.isNotEmpty ?? false)
                ? p!.displayName
                : 'Direct message',
            orElse: () => 'Direct message',
          );

    final subtitle = thread.isGroup
        ? (thread.memberUids.isNotEmpty
              ? '${thread.memberUids.length} members'
              : 'Group chat')
        : 'You’re connected';

    final hint = thread.isGroup ? 'Say hi to your group.' : 'Say hi to $title.';

    Widget avatar = CircleAvatar(
      radius: 54,
      backgroundColor: cs.primaryContainer,
      child: Icon(
        thread.isGroup ? Icons.groups : Icons.person,
        color: cs.onPrimaryContainer,
        size: 40,
      ),
    );

    if (thread.isGroup) {
      final url = thread.photoUrl;
      if (url != null && url.isNotEmpty) {
        avatar = CircleAvatar(radius: 54, backgroundImage: NetworkImage(url));
      }
    } else {
      avatar = profileAsync.maybeWhen(
        data: (p) {
          final url = p?.photoUrl;
          if (url != null && url.isNotEmpty) {
            return CircleAvatar(radius: 54, backgroundImage: NetworkImage(url));
          }
          return CircleAvatar(
            radius: 54,
            backgroundColor: cs.primaryContainer,
            child: Icon(Icons.person, color: cs.onPrimaryContainer, size: 40),
          );
        },
        orElse: () => avatar,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        avatar,
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ThreadAvatar extends StatelessWidget {
  const _ThreadAvatar({required this.thread, required this.profileAsync});

  final ChatThread thread;
  final AsyncValue<UserProfile?> profileAsync;

  @override
  Widget build(BuildContext context) {
    if (thread.isGroup) {
      final url = thread.photoUrl;
      return CircleAvatar(
        radius: 20,
        backgroundImage: (url == null || url.isEmpty)
            ? null
            : NetworkImage(url),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: (url == null || url.isEmpty)
            ? const Icon(Icons.groups, size: 20)
            : null,
      );
    }

    return profileAsync.when(
      data: (p) {
        final url = p?.photoUrl;
        final online = p?.online == true;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundImage: (url == null || url.isEmpty)
                  ? null
                  : NetworkImage(url),
              child: (url == null || url.isEmpty)
                  ? const Icon(Icons.person)
                  : null,
            ),
            if (online)
              Positioned(
                bottom: -1,
                right: -1,
                child: Container(
                  height: 12,
                  width: 12,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.surface,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
      loading: () => CircleAvatar(
        radius: 20,
        child: SizedBox(
          height: 14,
          width: 14,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (error, stackTrace) =>
          const CircleAvatar(radius: 20, child: Icon(Icons.person)),
    );
  }
}

class _ReadAvatars extends StatelessWidget {
  const _ReadAvatars({
    required this.thread,
    required this.myUid,
    required this.sentAt,
  });

  final ChatThread? thread;
  final String? myUid;
  final DateTime sentAt;

  @override
  Widget build(BuildContext context) {
    final reads = thread?.memberReads;
    if (reads == null || reads.isEmpty) return const SizedBox.shrink();
    final readers = reads.entries
        .where((e) => e.key != myUid && e.value.isAfter(sentAt))
        .map((e) => e.key)
        .toList();
    if (readers.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 4),
        ...readers
            .take(5)
            .map(
              (uid) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    _initials(uid),
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  static String _initials(String uid) {
    if (uid.isEmpty) return '?';
    return uid.length >= 2
        ? uid.substring(0, 2).toUpperCase()
        : uid[0].toUpperCase();
  }
}

class _TypingIndicator extends ConsumerWidget {
  const _TypingIndicator({required this.threadAsync, required this.myUid});

  final AsyncValue<ChatThread?> threadAsync;
  final String? myUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return threadAsync.when(
      data: (thread) {
        if (thread == null) return const SizedBox.shrink();
        final typing = thread.typing;
        if (typing == null || typing.isEmpty) return const SizedBox.shrink();

        final typingIds = typing.entries
            .where((e) => e.key != myUid && e.value == true)
            .map((e) => e.key)
            .toList();
        if (typingIds.isEmpty) return const SizedBox.shrink();

        final first = typingIds.first;
        final profile = ref.watch(userProfileProvider(first));
        final avatarUrl = profile.maybeWhen(
          data: (p) => p?.photoUrl,
          orElse: () => null,
        );
        final displayName = profile.maybeWhen(
          data: (p) =>
              (p?.displayName.isNotEmpty ?? false) ? p!.displayName : 'Someone',
          orElse: () => 'Someone',
        );
        final label = typingIds.length == 1
            ? '$displayName is typing...'
            : '$displayName +${typingIds.length - 1} are typing...';

        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
              boxShadow: [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundImage: (avatarUrl == null || avatarUrl.isEmpty)
                        ? null
                        : NetworkImage(avatarUrl),
                    child: (avatarUrl == null || avatarUrl.isEmpty)
                        ? const Icon(Icons.person, size: 14)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  const _TypingDots(),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.9),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _dot1;
  late final Animation<double> _dot2;
  late final Animation<double> _dot3;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();

    _dot1 = Tween(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.7, curve: Curves.easeInOut),
      ),
    );
    _dot2 = Tween(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 0.9, curve: Curves.easeInOut),
      ),
    );
    _dot3 = Tween(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.4, 1.0, curve: Curves.easeInOut),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dots = [_dot1, _dot2, _dot3];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: dots
          .map(
            (anim) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: FadeTransition(
                opacity: anim,
                child: const CircleAvatar(radius: 3),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _GifItem {
  const _GifItem({
    required this.id,
    required this.previewUrl,
    required this.fullUrl,
  });

  final String id;
  final String previewUrl;
  final String fullUrl;
}

class _MediaTray extends StatelessWidget {
  const _MediaTray({
    required this.tabController,
    required this.theme,
    required this.colorScheme,
    required this.searchController,
    required this.searchFocusNode,
    required this.loading,
    required this.error,
    required this.gifs,
    required this.emojiPalette,
    required this.onClose,
    required this.onPickGif,
    required this.onPickEmoji,
  });

  final TabController tabController;
  final ThemeData theme;
  final ColorScheme colorScheme;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool loading;
  final String? error;
  final List<_GifItem> gifs;
  final List<String> emojiPalette;
  final VoidCallback onClose;
  final ValueChanged<String> onPickGif;
  final ValueChanged<String> onPickEmoji;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;

    return AnimatedBuilder(
      animation: tabController,
      builder: (context, _) {
        final tabIndex = tabController.index;
        final q = searchController.text.trim();

        Widget body;
        if (tabIndex == 2) {
          body = GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: emojiPalette.length,
            itemBuilder: (context, i) {
              final e = emojiPalette[i];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                mouseCursor: SystemMouseCursors.click,
                onTap: () => onPickEmoji(e),
                child: Center(
                  child: Text(e, style: const TextStyle(fontSize: 22)),
                ),
              );
            },
          );
        } else if (tabIndex == 0) {
          body = Center(
            child: Text(
              'Stickers',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          );
        } else {
          if (loading) {
            body = const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          } else if (error != null) {
            body = Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            );
          } else {
            body = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.trending_up,
                        size: 16,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        q.isEmpty ? 'Trending' : 'Results',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                        ),
                    itemCount: gifs.length,
                    itemBuilder: (context, i) {
                      final g = gifs[i];
                      return InkWell(
                        mouseCursor: SystemMouseCursors.click,
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onPickGif(g.fullUrl),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(g.previewUrl, fit: BoxFit.cover),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          }
        }

        return DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: body,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Close',
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          controller: searchController,
                          focusNode: searchFocusNode,
                          enabled: tabIndex == 1,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Search GIFs across apps...',
                            border: InputBorder.none,
                            isDense: true,
                            prefixIcon: Icon(
                              Icons.search,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TabBar(
                  controller: tabController,
                  labelColor: cs.onSurface,
                  unselectedLabelColor: cs.onSurfaceVariant,
                  indicatorColor: cs.primary,
                  onTap: (_) {
                    FocusScope.of(context).requestFocus(searchFocusNode);
                  },
                  tabs: const [
                    Tab(text: 'STICKERS'),
                    Tab(text: 'GIFs'),
                    Tab(text: 'EMOJI'),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
