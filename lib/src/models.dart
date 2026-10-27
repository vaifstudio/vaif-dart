/// Public data types returned by the SDK.
library;

import 'dart:typed_data';

/// A project end user (`/projects/:projectId/auth`).
class User {
  /// Creates a user; the SDK builds these from API responses.
  const User({
    required this.id,
    this.email,
    this.phone,
    this.provider,
    this.metadata,
    this.emailVerifiedAt,
    this.createdAt,
    this.raw = const {},
  });

  /// Builds a user from the API's JSON.
  factory User.fromJson(Map<String, dynamic> json) => User(
    id: '${json['id'] ?? ''}',
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    provider: json['provider'] as String?,
    metadata: json['metadata'],
    emailVerifiedAt: json['emailVerifiedAt'] as String?,
    createdAt: json['createdAt'] as String?,
    raw: Map<String, dynamic>.unmodifiable(json),
  );

  /// The user's ID.
  final String id;

  /// The user's email address, when they have one.
  final String? email;

  /// The user's phone number, when they have one.
  final String? phone;

  /// How the user signs in, for example `email`, `google` or `github`.
  final String? provider;

  /// The metadata stored with the user at sign-up.
  final Object? metadata;

  /// When the email address was verified (ISO 8601), or null.
  final String? emailVerifiedAt;

  /// When the user was created (ISO 8601).
  final String? createdAt;

  /// Every field the API returned, including ones this class does not model.
  final Map<String, dynamic> raw;

  /// The API's JSON shape, suitable for [User.fromJson].
  Map<String, dynamic> toJson() =>
      raw.isNotEmpty
          ? Map<String, dynamic>.of(raw)
          : {
            'id': id,
            if (email != null) 'email': email,
            if (phone != null) 'phone': phone,
            if (provider != null) 'provider': provider,
            if (metadata != null) 'metadata': metadata,
            if (emailVerifiedAt != null) 'emailVerifiedAt': emailVerifiedAt,
            if (createdAt != null) 'createdAt': createdAt,
          };

  @override
  String toString() => 'User(id: $id, email: $email)';
}

/// An authenticated end-user session.
///
/// [refreshToken] is the opaque rotating token: from the response body for a
/// project client, or from the `refresh_token` cookie for a platform client.
/// To keep users signed in, give the client a `SessionStorage`, or save the
/// session with [toJson] in secure storage and restore it with
/// `AuthClient.restoreSession`.
class Session {
  /// Creates a session from its parts.
  const Session({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
    this.user,
  });

  /// Restores a session saved with [toJson].
  factory Session.fromJson(Map<String, dynamic> json) {
    final token = json['accessToken'];
    final expires = json['expiresAt'];
    if (token is! String || token.isEmpty || expires is! String) {
      throw const FormatException('Not a serialized VAIF session');
    }
    final user = json['user'];
    return Session(
      accessToken: token,
      expiresAt: DateTime.parse(expires).toUtc(),
      refreshToken: json['refreshToken'] as String?,
      user: user is Map<String, dynamic> ? User.fromJson(user) : null,
    );
  }

  /// The access token sent as `Authorization: Bearer`.
  final String accessToken;

  /// When the access token expires (UTC).
  final DateTime expiresAt;

  /// The rotating refresh token, when the API issued one.
  final String? refreshToken;

  /// The signed-in user, when the API returned one.
  final User? user;

  /// Time left before the access token expires (negative when expired).
  Duration get expiresIn => expiresAt.difference(DateTime.now().toUtc());

  /// Whether the access token expires within [leeway].
  bool isExpired([Duration leeway = Duration.zero]) => expiresIn <= leeway;

  /// JSON for secure persistence. Contains the refresh token: store it in
  /// the platform keychain / keystore, never in plain preferences.
  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (user != null) 'user': user!.toJson(),
  };

  /// Keeps both tokens out of logs.
  @override
  String toString() =>
      'Session(expiresAt: ${expiresAt.toIso8601String()}, '
      'user: ${user?.id}, hasRefreshToken: ${refreshToken != null})';
}

/// Outcome of `AuthClient.signIn`: a session, or an MFA challenge.
class SignInResult {
  /// Creates a result; the sign-in calls return these.
  const SignInResult({
    this.session,
    this.mfaRequired = false,
    this.challengeToken,
  });

  /// The new session, or null when [mfaRequired].
  final Session? session;

  /// True when the user has MFA enrolled; finish with `verifyMfa`.
  final bool mfaRequired;

  /// The token to pass to `verifyMfa` with the user's code.
  final String? challengeToken;

  @override
  String toString() =>
      'SignInResult(mfaRequired: $mfaRequired, session: $session)';
}

/// Outcome of `AuthClient.signUp`.
///
/// [session] is null when the API answers `pendingVerification` (for example
/// when the address already has an account: the API does not reveal which
/// addresses exist).
class SignUpResult {
  /// Creates a result; `AuthClient.signUp` returns these.
  const SignUpResult({
    this.session,
    this.user,
    this.pendingVerification = false,
    this.message,
  });

  /// The new session, or null when [pendingVerification].
  final Session? session;

  /// The new user, when the API returned one.
  final User? user;

  /// True when the user must verify the email address before signing in.
  final bool pendingVerification;

  /// The API's message for the user, if any.
  final String? message;
}

/// Rows from a list query and the total number of matching rows.
class ListResult {
  /// Creates a result; `QueryBuilder.list` returns these.
  const ListResult({required this.data, required this.count});

  /// The rows, as the data API returns them.
  final List<Map<String, dynamic>> data;

  /// The number of rows the query matches; more than `data.length` when a
  /// limit cut the list short.
  final int count;
}

/// One page of an offset-paginated query, from `QueryBuilder.paginate`.
class PageResult {
  /// Creates a page; `QueryBuilder.paginate` returns these.
  const PageResult({
    required this.data,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  /// The rows on this page.
  final List<Map<String, dynamic>> data;

  /// The number of rows the query matches across all pages.
  final int total;

  /// This page's number, starting at 1.
  final int page;

  /// The number of rows per page.
  final int pageSize;

  /// The number of pages.
  int get pageCount => pageSize > 0 ? (total + pageSize - 1) ~/ pageSize : 0;

  /// Whether a page follows this one.
  bool get hasNext => page < pageCount;

  /// Whether a page precedes this one.
  bool get hasPrevious => page > 1;
}

/// Result of `StorageClient.upload`.
class UploadResult {
  /// Creates a result; `StorageClient.upload` returns these.
  const UploadResult({required this.key, required this.size, this.bucket});

  /// The object's key.
  final String key;

  /// The bucket passed to `upload`, or null for the project's default.
  final String? bucket;

  /// The number of bytes uploaded.
  final int size;
}

/// The HTTP response produced by a function invocation.
///
/// [data] is decoded JSON for JSON responses, a [String] for `text/*`, a
/// [Uint8List] otherwise, and null for an empty body.
class FunctionResponse {
  /// Creates a response; `FunctionsClient.invoke` returns these.
  const FunctionResponse({
    required this.status,
    required this.headers,
    this.data,
  });

  /// The function's HTTP status.
  final int status;

  /// The function's response headers, with lowercase names.
  final Map<String, String> headers;

  /// The decoded body (see the class description).
  final Object? data;

  /// The raw body when the function returned binary data.
  Uint8List? get bytes => data is Uint8List ? data as Uint8List : null;
}
