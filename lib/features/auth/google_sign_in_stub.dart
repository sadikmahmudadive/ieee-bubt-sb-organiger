/// Stubbed Google Sign-In for web builds; actual web auth uses
/// FirebaseAuth + signInWithPopup instead of the plugin.
class GoogleSignIn {
  GoogleSignIn({String? clientId, List<String> scopes = const []});

  Future<void> initialize() async {}
  Future<GoogleSignInAccount?> signIn() async => null;
  Future<GoogleSignInAccount?> signInSilently() async => null;
}

class GoogleSignInAccount {
  GoogleSignInAccount(this._accessToken, this._idToken);
  final String? _accessToken;
  final String? _idToken;

  Future<GoogleSignInAuthentication> get authentication async =>
      GoogleSignInAuthentication(_accessToken, _idToken);
}

class GoogleSignInAuthentication {
  GoogleSignInAuthentication(this.accessToken, this.idToken);
  final String? accessToken;
  final String? idToken;
}
