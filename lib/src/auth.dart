part of 'client.dart';

/// Name of the cookie that carries an app user's rotating refresh token.
const String refreshCookieName = 'project_refresh_token';

/// Name of the cookie that carries a VAIF Studio account's refresh token
/// (a client created without `projectId`).
const String platformRefreshCookieName = 'refresh_token';

/// Request header that asks the API for the refresh token in the response
/// body. Project auth only: VAIF Studio's own accounts always use the cookie.
const String refreshModeHeader = 'x-vaif-refresh-mode';

/// Refresh this long before the access token expires.
const Duration refreshLeeway = Duration(seconds: 30);

/// True when compiled for the web, where the browser owns `Cookie`.
const bool _isWeb = bool.fromEnvironment('dart.library.js_interop');

/// Reads the rotating refresh token from a token-issuing response: the body's
/// `refreshToken` (body mode) first, else the [cookieName] `Set-Cookie`.
///
/// `package:http` folds repeated headers into one comma-separated value,
/// hence the pattern. A cleared cookie (empty value) reads as null.
String? refreshTokenFrom(
  http.Response response, {
  String cookieName = refreshCookieName,
}) {
  final body = responseObject(response);
  final token = body['refreshToken'];
  if (token is String && token.isNotEmpty) return token;
  final header = response.headers['set-cookie'];
  if (header == null) return null;
  final pattern = RegExp('(?:^|[,;]\\s*)${RegExp.escape(cookieName)}=([^;,]*)');
  final match = pattern.firstMatch(header);
  final raw = match?.group(1)?.trim();
  if (raw == null || raw.isEmpty) return null;
  try {
    return Uri.decodeComponent(raw);
  } on ArgumentError {
    return raw;
  }
}

/// What changed in the auth state.
enum AuthChangeEvent {
  /// A session was installed: a sign-in, `setSession`, `restoreSession` or
  /// `loadSession`.
  signedIn,

  /// The access token was refreshed for the same user.
  tokenRefreshed,

  /// The session ended: `signOut`, or a refresh the API refused.
  signedOut,
}

/// An auth state change and the session after it (null when signed out).
class AuthStateChange {
  /// Creates a change; the client reports these on `onAuthStateChange`.
  const AuthStateChange(this.event, this.session);

  /// What changed.
  final AuthChangeEvent event;

  /// The session after the change, or null when signed out.
  final Session? session;

  @override
  String toString() => 'AuthStateChange(${event.name})';
}

Session _sessionFrom(
  Map<String, dynamic> body,
  String? refreshToken, {
  User? fallbackUser,
}) {
  final token = body['accessToken'];
  if (token is! String || token.isEmpty) {
    throw VaifException(
      'The API response did not include an access token',
      body: body,
    );
  }
  final expiresIn = body['expiresIn'];
  final lifetime = expiresIn is num ? expiresIn : 900;
  final user = body['user'];
  return Session(
    accessToken: token,
    expiresAt: DateTime.now().toUtc().add(
      Duration(milliseconds: (lifetime * 1000).round()),
    ),
    refreshToken: refreshToken,
    user: user is Map<String, dynamic> ? User.fromJson(user) : fallbackUser,
  );
}

/// Signs end users in and out and keeps their session fresh.
///
/// The session is kept in memory. A client created with a [SessionStorage]
/// also saves it there and restores it with [loadSession]; see
/// `VaifClient.new`.
class AuthClient {
  AuthClient._(this._client, Session? session, this._storage)
    : _session = session {
    mfa = MfaClient._(this);
  }

  /// TOTP enrollment and backup codes for the signed-in user.
  late final MfaClient mfa;

  /// The signed-in user's device sessions.
  late final AuthSessionsClient sessions = AuthSessionsClient._(this);

  final Map<String, String> _pendingOAuth = {};

  final VaifClient _client;
  final SessionStorage? _storage;
  Session? _session;

  /// The tail of the storage calls, which run one at a time in the order
  /// they were made. Never completes with an error.
  Future<void> _storageQueue = Future.value();

  /// Counts the saves and deletes queued, so [loadSession] can tell whether
  /// the session changed while it read the storage.
  int _storageEpoch = 0;

  VaifSessionStorageException? _storageError;
  Future<Session>? _refreshing;
  Session? _refreshingFrom;

  /// Counts sign-ins and sign-outs, but not token refreshes, so a request
  /// can tell whether the user changed while it was in flight.
  int _generation = 0;
  final StreamController<AuthStateChange> _changes =
      StreamController.broadcast();

  /// The current session, or null when signed out.
  Session? get session => _session;

  /// Every change of [session]: [AuthChangeEvent.signedIn],
  /// [AuthChangeEvent.tokenRefreshed] and [AuthChangeEvent.signedOut].
  Stream<AuthStateChange> get onAuthStateChange => _changes.stream;

  /// The key under which the session is saved in the client's
  /// [SessionStorage]: the API base URL and the project ID (empty for a
  /// platform client), so clients for different projects, or for one project
  /// at different base URLs, never share a saved session.
  String get sessionStorageKey =>
      'vaif_client.session|${_client.baseUrl}|${_client.projectId ?? ''}';

  /// The last failure of the client's [SessionStorage], or null when its
  /// last read, save or delete succeeded.
  ///
  /// A session that could not be saved stays signed in for this run of the
  /// app, and the saved session is deleted, so the next launch signs in
  /// again rather than restoring an older session. Calls that sign in throw
  /// only when that delete fails too.
  VaifSessionStorageException? get sessionStorageError => _storageError;

  String _path(String suffix) =>
      _client.projectId == null
          ? '/auth/$suffix'
          : '/projects/${Uri.encodeComponent(_client.projectId!)}/auth/$suffix';

  /// Routes that exist only at `/projects/:projectId/auth/...`: fails locally
  /// with `PROJECT_ID_REQUIRED` instead of a 404 from a platform route.
  String _projectPath(String suffix) =>
      '/projects/${Uri.encodeComponent(_client.requiredProjectId)}/auth/$suffix';

  bool get _bodyMode => _client.projectId != null;

  String get _cookieName =>
      _bodyMode ? refreshCookieName : platformRefreshCookieName;

  /// Headers for a request that issues or redeems a refresh token.
  Map<String, String> get _tokenHeaders =>
      _bodyMode ? const {refreshModeHeader: 'body'} : const {};

  String? _refreshTokenFrom(http.Response response) =>
      refreshTokenFrom(response, cookieName: _cookieName);

  /// Installs [session] and reports [event]; then, with a [SessionStorage],
  /// saves the session (or deletes the saved one for null).
  ///
  /// The returned future completes when the storage is done. It throws
  /// [VaifSessionStorageException] when an older session may still be
  /// saved: a new session could not be saved and the saved one could not be
  /// deleted, or the delete for a sign-out failed. A save failure whose
  /// delete succeeded is recorded in [sessionStorageError] only.
  Future<void> _set(
    Session? session,
    AuthChangeEvent event, {
    bool save = true,
  }) {
    _session = session;
    if (event != AuthChangeEvent.tokenRefreshed) _generation++;
    _client.realtime.setAuth(session?.accessToken);
    if (!_changes.isClosed) _changes.add(AuthStateChange(event, session));
    return save ? _save(session) : Future.value();
  }

  /// Queues saving [session], or deleting the saved session for null, behind
  /// every earlier storage call. See [_set] for what the future reports.
  Future<void> _save(Session? session) {
    final storage = _storage;
    if (storage == null) return Future.value();
    _storageEpoch++;
    final done = _storageQueue.then((_) => _store(storage, session));
    _storageQueue = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  Future<void> _store(SessionStorage storage, Session? session) async {
    final key = sessionStorageKey;
    if (session != null) {
      try {
        await storage.write(key, _encodeSaved(session));
        _storageError = null;
        return;
      } catch (error) {
        _storageError = VaifSessionStorageException(
          'The session could not be saved; the saved session was deleted',
          cause: error,
        );
      }
    }
    try {
      await storage.delete(key);
      if (session == null) _storageError = null;
    } catch (error) {
      throw _storageError = VaifSessionStorageException(
        session == null
            ? 'The saved session could not be deleted'
            : 'The session could not be saved, and the session saved before '
                'it could not be deleted',
        cause: error,
      );
    }
  }

  String _encodeSaved(Session session) => jsonEncode({
    'baseUrl': _client.baseUrl,
    'projectId': _client.projectId,
    'session': session.toJson(),
  });

  /// The session in a saved value, or null when the value is not a session
  /// saved for this client's base URL and project.
  Session? _decodeSaved(String value) {
    try {
      final saved = jsonDecode(value);
      if (saved is! Map<String, dynamic> ||
          saved['baseUrl'] != _client.baseUrl ||
          saved['projectId'] != _client.projectId) {
        return null;
      }
      final session = saved['session'];
      return session is Map<String, dynamic> ? Session.fromJson(session) : null;
    } catch (_) {
      // Not JSON, or JSON of the wrong shape (FormatException, TypeError).
      return null;
    }
  }

  void _close() {
    unawaited(_changes.close());
  }

  /// Restores the session saved in the client's [SessionStorage].
  ///
  /// Returns the restored session, or null when none is saved. When the
  /// client already has a session, it is kept and returned without reading
  /// the storage. A saved value that is not a usable session (unreadable,
  /// saved for another base URL or project, or expired with no refresh
  /// token) is deleted. Throws [StateError] when the
  /// client has no [SessionStorage], and [VaifSessionStorageException] when
  /// the storage cannot be read.
  ///
  /// The read waits for earlier storage calls, and a sign-in or sign-out
  /// made while it runs wins: the saved value is then not restored, and the
  /// current session (null after a sign-out) is returned.
  Future<Session?> loadSession() async {
    final storage = _storage;
    if (storage == null) {
      throw StateError('Create the client with sessionStorage to load one');
    }
    if (_session != null) return _session;
    final epoch = _storageEpoch;
    final read = _storageQueue.then((_) => storage.read(sessionStorageKey));
    _storageQueue = read.then((_) {}, onError: (Object _) {});
    final String? value;
    try {
      value = await read;
      _storageError = null;
    } catch (error) {
      throw _storageError = VaifSessionStorageException(
        'The saved session could not be read',
        cause: error,
      );
    }
    // A sign-in, sign-out or refresh made while the storage was read wins.
    if (_storageEpoch != epoch || _session != null) return _session;
    if (value == null) return null;
    final session = _decodeSaved(value);
    final refresh = session?.refreshToken;
    if (session == null ||
        (session.isExpired() && (refresh == null || refresh.isEmpty))) {
      try {
        await _save(null);
      } on VaifSessionStorageException {
        // Recorded in sessionStorageError; the value stays unusable.
      }
      return null;
    }
    await _set(session, AuthChangeEvent.signedIn, save: false);
    return session;
  }

  /// Signs in with a session the app saved itself (see [Session.toJson]).
  /// With a [SessionStorage], the session is also saved there; this throws
  /// [VaifSessionStorageException] as the sign-in calls do.
  Future<void> restoreSession(Session session) =>
      _set(session, AuthChangeEvent.signedIn);

  /// Signs in with a session from its parts, for example the tokens a magic
  /// link delivers. Without [expiresAt] the access token is treated as valid
  /// for one hour. With a [SessionStorage], the session is also saved there;
  /// this throws [VaifSessionStorageException] as the sign-in calls do.
  Future<Session> setSession(
    String accessToken, {
    String? refreshToken,
    DateTime? expiresAt,
    User? user,
  }) async {
    if (accessToken.isEmpty) {
      throw ArgumentError.value(
        accessToken,
        'accessToken',
        'must not be empty',
      );
    }
    final session = Session(
      accessToken: accessToken,
      expiresAt:
          (expiresAt ?? DateTime.now().add(const Duration(hours: 1))).toUtc(),
      refreshToken: refreshToken,
      user: user,
    );
    await _set(session, AuthChangeEvent.signedIn);
    return session;
  }

  /// Creates an account with email and password.
  Future<SignUpResult> signUp(
    String email,
    String password, {
    Map<String, Object?>? metadata,
    String? phone,
  }) async {
    if (_client.projectId == null) throw VaifConsoleOnlyError.signUp();
    final response = await _client._transport.request(
      'POST',
      _path('signup'),
      headers: _tokenHeaders,
      json: {
        'email': email,
        'password': password,
        if (metadata != null) 'metadata': metadata,
        if (phone != null) 'phone': phone,
      },
    );
    final body = responseObject(response);
    final userJson = body['user'];
    final user =
        userJson is Map<String, dynamic> ? User.fromJson(userJson) : null;
    if (body['accessToken'] != null) {
      final session = _sessionFrom(body, _refreshTokenFrom(response));
      await _set(session, AuthChangeEvent.signedIn);
      return SignUpResult(session: session, user: session.user ?? user);
    }
    final pending = body['pendingVerification'];
    return SignUpResult(
      user: user,
      pendingVerification: pending is bool ? pending : true,
      message: body['message'] as String?,
    );
  }

  /// Signs in with email and password.
  ///
  /// When the user has MFA enrolled the result has `mfaRequired` and a
  /// `challengeToken`; finish with [verifyMfa].
  Future<SignInResult> signIn(String email, String password) async {
    final response = await _client._transport.request(
      'POST',
      _path('login'),
      headers: _tokenHeaders,
      json: {'email': email, 'password': password},
    );
    final body = responseObject(response);
    if (body['mfaRequired'] == true) {
      return SignInResult(
        mfaRequired: true,
        challengeToken: body['challengeToken'] as String?,
      );
    }
    final session = _sessionFrom(body, _refreshTokenFrom(response));
    await _set(session, AuthChangeEvent.signedIn);
    return SignInResult(session: session);
  }

  /// Completes an MFA sign-in with a TOTP or backup code.
  Future<Session> verifyMfa(String challengeToken, String code) async {
    final response = await _client._transport.request(
      'POST',
      _path('mfa/verify'),
      headers: _tokenHeaders,
      json: {'challengeToken': challengeToken, 'code': code},
    );
    final session = _sessionFrom(
      responseObject(response),
      _refreshTokenFrom(response),
    );
    await _set(session, AuthChangeEvent.signedIn);
    return session;
  }

  /// Exchanges the refresh token for a new access token.
  ///
  /// Concurrent callers for the same session share a single in-flight
  /// refresh, so a burst of requests with an expired token triggers exactly
  /// one network call. The API rotates the refresh token on every use.
  Future<Session> refreshSession() {
    final current = _session;
    final pending = _refreshing;
    if (pending != null && identical(_refreshingFrom, current)) return pending;
    final refresh = _refreshOnce(current);
    _refreshing = refresh;
    _refreshingFrom = current;
    refresh.whenComplete(() {
      if (identical(_refreshing, refresh)) {
        _refreshing = null;
        _refreshingFrom = null;
      }
    }).ignore();
    return refresh;
  }

  Future<Session> _refreshOnce(Session? current) async {
    final token = current?.refreshToken;
    if (current == null || token == null || token.isEmpty) {
      throw VaifAuthException(
        'No refresh token available; sign in again',
        code: 'NO_REFRESH_TOKEN',
      );
    }
    final http.Response response;
    try {
      response = await _client._transport.request(
        'POST',
        _path('refresh'),
        json: {'refreshToken': token},
        headers: {..._tokenHeaders, ..._refreshCookie(token)},
      );
    } on VaifAuthException {
      // Revoked or expired refresh token: the session is over.
      // A storage failure is recorded in sessionStorageError; the refresh's
      // own error is the one to report.
      if (identical(_session, current)) {
        _set(null, AuthChangeEvent.signedOut).ignore();
      }
      rethrow;
    }
    if (!identical(_session, current)) {
      // Signed out (or into another account) while the refresh was in
      // flight: the old session must not come back. After a sign-out, the
      // server may have rotated the refresh token before the logout reached
      // it, so the logout found no session to end; end the one this refresh
      // received.
      if (_session == null) {
        try {
          final issued = responseObject(response)['accessToken'];
          await _logout(
            issued is String && issued.isNotEmpty ? issued : null,
            _refreshTokenFrom(response),
          );
        } on VaifException {
          // Best effort: the caller has already signed out.
        }
      }
      throw VaifAuthException(
        'The session changed during refresh',
        code: 'SESSION_CHANGED',
      );
    }
    final rotated = _refreshTokenFrom(response) ?? token;
    final session = _sessionFrom(
      responseObject(response),
      rotated,
      fallbackUser: current.user,
    );
    // A refresh never fails because of the storage; a failure is recorded
    // in sessionStorageError.
    _set(session, AuthChangeEvent.tokenRefreshed).ignore();
    return session;
  }

  /// Outside a browser, the refresh token as the cookie the API reads it
  /// from. In a browser, the browser owns `Cookie`.
  Map<String, String> _refreshCookie(String token) =>
      _isWeb
          ? const {}
          : {'cookie': '$_cookieName=${Uri.encodeComponent(token)}'};

  /// Asks the server to end the session that [accessToken] or
  /// [refreshToken] names. The server identifies the user by the access
  /// token, or by the refresh token once the access token has expired.
  Future<void> _logout(String? accessToken, String? refreshToken) async {
    final hasRefresh = refreshToken != null && refreshToken.isNotEmpty;
    if (accessToken == null && !hasRefresh) return;
    await _client._transport.request(
      'POST',
      _path('logout'),
      bearer: accessToken,
      json: {if (hasRefresh) 'refreshToken': refreshToken},
      headers: hasRefresh ? _refreshCookie(refreshToken) : null,
    );
  }

  /// Revokes the session on the server and clears it locally.
  ///
  /// The session is cleared locally first, so a refresh in flight cannot
  /// restore it, then the server is asked to end it. The request carries the
  /// refresh token as well as the access token, so it works after the access
  /// token has expired. The server signs the user out of every session. The
  /// local session is cleared even if the server call fails; a 401 is not
  /// treated as an error.
  ///
  /// With a [SessionStorage], the saved session is deleted, and this throws
  /// [VaifSessionStorageException] when it could not be, since the session
  /// would otherwise be restored on the next launch. Calling [signOut] again
  /// retries the delete.
  Future<void> signOut() async {
    final current = _session;
    if (current == null) return _save(null);
    final deleted = _set(null, AuthChangeEvent.signedOut);
    try {
      await _logout(current.accessToken, current.refreshToken);
    } on VaifAuthException catch (error) {
      if (error.status != 401) {
        await deleted;
        rethrow;
      }
    } on VaifException {
      await deleted;
      rethrow;
    }
    await deleted;
  }

  /// Fetches the signed-in user's profile.
  Future<User> getUser() async {
    final response = await _client._send(
      'GET',
      _path('me'),
      requireSession: true,
    );
    final body = responseObject(response);
    final user = body['user'];
    if (user is! Map<String, dynamic>) {
      throw VaifException(
        'The API response did not include a user',
        body: body,
      );
    }
    return User.fromJson(user);
  }

  /// Emails a password-reset link. Succeeds whether or not the address exists.
  Future<void> requestPasswordReset(String email) async {
    if (_client.projectId == null) throw VaifConsoleOnlyError.passwordReset();
    await _client._transport.request(
      'POST',
      _path('forgot-password'),
      json: {'email': email},
    );
  }

  /// Sets a new password using the token from the reset email.
  Future<void> resetPassword(String token, String newPassword) async {
    await _client._transport.request(
      'POST',
      _path('reset-password'),
      json: {'token': token, 'password': newPassword},
    );
  }

  /// Starts project-user OAuth. Open the returned URL with your platform's launcher.
  /// Keep the returned state/verifier securely if the app can restart mid-flow.
  Future<OAuthSignInResult> getOAuthSignInUrl({
    required String provider,
    required String redirectUrl,
    String? codeVerifier,
    String? state,
  }) async {
    _client.requiredProjectId;
    if (!{'google', 'github'}.contains(provider)) {
      throw ArgumentError.value(
        provider,
        'provider',
        'must be google or github',
      );
    }
    final redirect = Uri.tryParse(redirectUrl);
    if (redirect == null || !redirect.hasScheme) {
      throw ArgumentError.value(redirectUrl, 'redirectUrl', 'must be absolute');
    }
    final verifier = codeVerifier ?? _randomUrlSafe(32);
    if (!RegExp(r'^[A-Za-z0-9._~-]{43,128}$').hasMatch(verifier)) {
      throw ArgumentError.value(
        verifier,
        'codeVerifier',
        'must be 43-128 PKCE characters',
      );
    }
    final nonce = state ?? _randomUrlSafe(16);
    if (nonce.isEmpty) {
      throw ArgumentError.value(state, 'state', 'must not be empty');
    }
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final response = await _client._transport.request(
      'POST',
      _path('oauth/$provider/start'),
      json: {
        'redirectUrl': redirectUrl,
        'state': nonce,
        'codeChallenge': challenge,
        'codeChallengeMethod': 'S256',
      },
    );
    final body = responseObject(response);
    final url = body['url'];
    if (url is! String || url.isEmpty) {
      throw VaifException('OAuth response did not include a URL');
    }
    // Bound retained state even if callers repeatedly abandon flows.
    if (_pendingOAuth.length >= 16) {
      _pendingOAuth.remove(_pendingOAuth.keys.first);
    }
    _pendingOAuth[nonce] = verifier;
    return OAuthSignInResult(url: url, state: nonce, codeVerifier: verifier);
  }

  /// Exchanges a one-time code. Saved state is consumed once. After a restart,
  /// supply the securely saved verifier and check callback state against saved state.
  Future<SignInResult> handleOAuthCallback({
    required String code,
    required String state,
    String? codeVerifier,
  }) async {
    _client.requiredProjectId;
    final saved = _pendingOAuth.remove(state);
    final verifier = codeVerifier ?? saved;
    if (state.isEmpty ||
        verifier == null ||
        (saved != null && verifier != saved)) {
      throw VaifException(
        'No sign-in matches this callback; start sign-in again',
        code: 'OAUTH_STATE_MISMATCH',
      );
    }
    if (code.isEmpty ||
        !RegExp(r'^[A-Za-z0-9._~-]{43,128}$').hasMatch(verifier)) {
      throw ArgumentError('A code and valid PKCE verifier are required');
    }
    final response = await _client._transport.request(
      'POST',
      _path('oauth/token'),
      headers: _tokenHeaders,
      json: {'code': code, 'codeVerifier': verifier},
    );
    final body = responseObject(response);
    if (body['mfaRequired'] == true) {
      return SignInResult(
        mfaRequired: true,
        challengeToken: body['challengeToken'] as String?,
      );
    }
    final session = _sessionFrom(body, _refreshTokenFrom(response));
    await _set(session, AuthChangeEvent.signedIn);
    return SignInResult(session: session);
  }

  /// The sign-in providers enabled for this project (`google`, `github`).
  Future<List<Map<String, dynamic>>> listOAuthProviders() async {
    final body = responseObject(
      await _client._send('GET', _projectPath('oauth/providers')),
    );
    final providers = body['providers'];
    return providers is List
        ? [
          for (final p in providers)
            if (p is Map<String, dynamic>) p,
        ]
        : <Map<String, dynamic>>[];
  }

  /// Emails a passwordless sign-in link. The link opens [redirectUrl] (one
  /// of the project's Redirect URLs) with `access_token`, `expires_in`
  /// (seconds) and `refresh_token` in the URL fragment; pass them to
  /// [setSession]. The API answers the same whether or not the address has
  /// an account.
  Future<void> sendMagicLink(String email, {String? redirectUrl}) async {
    if (email.isEmpty) {
      throw ArgumentError.value(email, 'email', 'must not be empty');
    }
    await _client._transport.request(
      'POST',
      _projectPath('magic/send'),
      json: {
        'email': email,
        if (redirectUrl != null) 'redirectUrl': redirectUrl,
        // Body mode: the link's fragment then carries the refresh token too.
        'refreshMode': 'body',
      },
    );
  }

  /// Emails the signed-in user a verification link.
  Future<void> sendEmailVerification() async {
    await _client._send(
      'POST',
      _projectPath('verify-email/send'),
      requireSession: true,
      json: const <String, Object?>{},
    );
  }

  /// Confirms an email address with the token from the verification email.
  Future<void> confirmEmailVerification(String token) async {
    if (token.isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    await _client._send(
      'POST',
      _projectPath('verify-email/confirm'),
      json: {'token': token},
    );
  }

  static String _randomUrlSafe(int size) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(size, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  /// Access token for an outgoing request, refreshed first if about to expire.
  Future<String?> _bearer() async {
    var session = _session;
    if (session == null) return null;
    final refresh = session.refreshToken;
    if (refresh != null &&
        refresh.isNotEmpty &&
        session.isExpired(refreshLeeway)) {
      session = await refreshSession();
    }
    return session.accessToken;
  }

  bool get _canRefresh {
    final token = _session?.refreshToken;
    return token != null && token.isNotEmpty;
  }
}

/// Project-user TOTP enrollment and backup-code management.
class MfaClient {
  MfaClient._(this._auth);
  final AuthClient _auth;

  Future<Map<String, dynamic>> _call(String suffix, [Object? body]) async =>
      responseObject(
        await _auth._client._send(
          'POST',
          _auth._path('mfa/$suffix'),
          requireSession: true,
          json: body,
        ),
      );

  /// Starts TOTP enrollment for the signed-in user.
  ///
  /// Returns `enrollToken`, `otpauthUri` (for a QR code), `secret` (for
  /// manual entry) and `expiresInSeconds`. Do not log these values. The API
  /// answers 409 when the user is already enrolled.
  Future<Map<String, dynamic>> enrollStart() => _call('enroll-start');

  /// Completes enrollment with the `enrollToken` from [enrollStart] and the
  /// first [code] from the authenticator app. Returns `backupCodes`, shown
  /// only this once.
  Future<Map<String, dynamic>> enrollConfirm(String enrollToken, String code) =>
      _call('enroll-confirm', {'enrollToken': enrollToken, 'code': code});

  /// Completes an MFA sign-in; the same as `AuthClient.verifyMfa`.
  Future<Session> verify(String challengeToken, String code) =>
      _auth.verifyMfa(challengeToken, code);

  /// Removes MFA from the signed-in user's account. [code] is a current
  /// TOTP code or a backup code.
  Future<Map<String, dynamic>> disable(String code) =>
      _call('disable', {'code': code});

  /// Replaces the backup codes. [code] must be a current TOTP code, not a
  /// backup code. Returns the new `backupCodes`, shown only this once.
  Future<Map<String, dynamic>> regenerateCodes(String code) =>
      _call('regenerate-codes', {'code': code});
}

/// The signed-in app user's device sessions
/// (`/projects/:projectId/auth/sessions`).
class AuthSessionsClient {
  AuthSessionsClient._(this._auth);
  final AuthClient _auth;

  /// Active sessions, newest first, with device and last-seen details.
  Future<List<Map<String, dynamic>>> list() async {
    final body = responseObject(
      await _auth._client._send(
        'GET',
        _auth._projectPath('sessions'),
        requireSession: true,
      ),
    );
    final sessions = body['sessions'];
    return sessions is List
        ? [
          for (final s in sessions)
            if (s is Map<String, dynamic>) s,
        ]
        : <Map<String, dynamic>>[];
  }

  /// Signs one session out.
  Future<void> revoke(String sessionId) async {
    final segment = _pathSegment(sessionId, 'sessionId');
    await _auth._client._send(
      'DELETE',
      _auth._projectPath('sessions/$segment'),
      requireSession: true,
    );
  }

  /// Signs out every other session; returns how many were revoked.
  Future<int> revokeAll() async {
    final body = responseObject(
      await _auth._client._send(
        'DELETE',
        _auth._projectPath('sessions'),
        requireSession: true,
      ),
    );
    final revoked = body['revoked'];
    return revoked is num ? revoked.toInt() : 0;
  }
}

/// OAuth start result. Contains secret PKCE state; do not log it.
class OAuthSignInResult {
  /// Creates a result; `AuthClient.getOAuthSignInUrl` returns these.
  const OAuthSignInResult({
    required this.url,
    required this.state,
    required this.codeVerifier,
  });

  /// The provider's sign-in page; open it with the platform's launcher.
  final String url;

  /// The value the callback must return as `state`.
  final String state;

  /// The PKCE verifier to pass to `handleOAuthCallback` after a restart.
  final String codeVerifier;
}
