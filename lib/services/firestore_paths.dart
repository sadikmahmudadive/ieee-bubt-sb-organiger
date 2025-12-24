class FirestorePaths {
  static const users = 'users';
  static const committeeMembers = 'committee_members';
  static const events = 'events';
  static const chatThreads = 'chat_threads';
  static const photoPosts = 'photo_posts';

  static String threadMessages(String threadId) =>
      'chat_threads/$threadId/messages';
}
