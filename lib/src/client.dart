/// The VAIF client: one object per project, shared by every module.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'exceptions.dart';
import 'generated/operations.dart';
import 'models.dart';
import 'operations.dart';
import 'realtime.dart';
import 'retry.dart';
import 'session_storage.dart';
import 'transport.dart';

part 'auth.dart';
part 'database.dart';
part 'functions.dart';
part 'storage.dart';

/// The production API origin.
const String defaultBaseUrl = 'https://api.vaif.studio';

/// Per-attempt timeout used when none is given.
const Duration defaultTimeout = Duration(seconds: 30);

/// Replaces the wait between [client]'s retries with [sleep].
///
/// For this package's tests, which record the delays instead of waiting.
/// Not exported from `package:vaif_client/vaif_client.dart`.
void debugSetRetrySleep(
  VaifClient client,
  Future<void> Function(Duration delay) sleep,
) => client._transport.sleep = sleep;

/// [value] URL-encoded as one path segment.
///
/// Throws [ArgumentError] for an empty value and for `.` and `..`, which
/// encoding leaves as they are and URL parsing would resolve to another
/// path.
String _pathSegment(String value, String name) {
  if (value.isEmpty || value == '.' || value == '..') {
    throw ArgumentError.value(value, name, "must not be empty, '.' or '..'");
  }
  return Uri.encodeComponent(value);
}

/// The header the API sets on every response a deployed function produced
/// (`POST /functions/:name/invoke`), and on no other response.
const String functionRunHeader = 'x-vaif-run-id';

/// Client for a VAIF Studio project.
///
/// ```dart
/// final vaif = VaifClient(projectId: 'proj_123', apiKey: 'vk_pub_...');
/// await vaif.auth.signIn('ada@example.com', 'password');
/// final todos = await vaif.from('todos').eq('done', false).list();
/// vaif.close();
/// ```
class VaifClient {
  /// Creates a client.
  ///
  /// [apiKey] is a project key (`vk_pub_...` for apps; `vk_srv_...` only on
  /// trusted servers) sent as `x-vaif-key`. [baseUrl] must be https, except
  /// http for localhost, 127.0.0.1 and ::1. [timeout] bounds each attempt,
  /// including reading the response. Pass [httpClient] to reuse your own
  /// `http.Client` (you close it), and [session] to start with a session the
  /// app saved itself. With [sessionStorage], the client saves the session
  /// there and `auth.loadSession()` restores it; [session] and
  /// [sessionStorage] cannot be combined. [realtimeChannelFactory] replaces
  /// `WebSocketChannel.connect` (tests, or a platform-specific WebSocket).
  VaifClient({
    this.projectId,
    required String apiKey,
    String baseUrl = defaultBaseUrl,
    Duration timeout = defaultTimeout,
    RetryPolicy retry = const RetryPolicy(),
    Map<String, String>? headers,
    http.Client? httpClient,
    Session? session,
    SessionStorage? sessionStorage,
    WebSocketChannel Function(Uri uri)? realtimeChannelFactory,
  }) : _transport = HttpTransport(
         baseUrl: baseUrl,
         apiKey: apiKey,
         timeout: timeout,
         retry: retry,
         headers: headers,
         httpClient: httpClient,
       ) {
    if (projectId != null) _pathSegment(projectId!, 'projectId');
    if (session != null && sessionStorage != null) {
      throw ArgumentError.value(
        session,
        'session',
        'cannot be combined with sessionStorage; '
            'call auth.loadSession() or auth.setSession() instead',
      );
    }
    auth = AuthClient._(this, session, sessionStorage);
    storage = StorageClient._(this);
    functions = FunctionsClient._(this);
    operations = Operations(OperationsRuntime(_send, stream: _stream).call);
    realtime = RealtimeClient(
      baseUrl: this.baseUrl,
      apiKey: apiKey,
      accessToken: () => auth._bearer(),
      timeout: timeout,
      channelFactory: realtimeChannelFactory,
    );
  }

  /// The project this client talks to.
  final String? projectId;

  /// Requires project scope for data-plane operations.
  String get requiredProjectId =>
      projectId ??
      (throw VaifException(
        'Create the client with your projectId',
        code: 'PROJECT_ID_REQUIRED',
      ));

  final HttpTransport _transport;

  /// End-user authentication.
  late final AuthClient auth;

  /// File storage.
  late final StorageClient storage;

  /// Deployed functions.
  late final FunctionsClient functions;

  /// One generated method per API operation with a success contract.
  late final Operations operations;

  /// WebSocket database change subscriptions.
  late final RealtimeClient realtime;

  /// The normalized API origin.
  String get baseUrl => _transport.baseUrl;

  /// Starts a query against [table].
  QueryBuilder from(String table) => QueryBuilder._(this, table);

  /// Closes the realtime connection, the auth state stream and the HTTP
  /// client the SDK created (not one passed as `httpClient`).
  void close() {
    realtime.disconnect();
    _transport.close();
    auth._close();
  }

  Future<http.StreamedResponse> _stream(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? json,
    Object? body,
    Map<String, String>? headers,
  }) async {
    _refuseConsoleOnly(method, path);
    final generation = auth._generation;
    final bearer = await auth._bearer();
    Future<http.StreamedResponse> send(String? token) =>
        _transport.requestStream(
          method,
          path,
          query: query,
          json: json,
          body: body,
          headers: headers,
          bearer: token,
        );
    try {
      return await send(bearer);
    } on VaifAuthException catch (error) {
      final token = await _retryToken(error, bearer, generation);
      if (token == null) rethrow;
      return send(token);
    }
  }

  /// The access token to send a request again with after the API answered
  /// it with [error], or null when [error] is the result.
  ///
  /// Only the API's own 401 on a request that carried a session token
  /// ([bearer]) is retried, once, and only while the user who sent it is
  /// still signed in ([generation] unchanged): a request must never be
  /// replayed with another user's token. A 401 that a function returned
  /// (it carries [functionRunHeader]) is the function's answer: the function
  /// has already run, and the session is not what it refused.
  Future<String?> _retryToken(
    VaifAuthException error,
    String? bearer,
    int generation,
  ) async {
    if (error.status != 401 ||
        error.headers?[functionRunHeader] != null ||
        bearer == null ||
        auth._generation != generation ||
        !auth._canRefresh) {
      return null;
    }
    final current = auth.session!;
    // Another request may already have refreshed this session.
    if (current.accessToken != bearer) return current.accessToken;
    return (await auth.refreshSession()).accessToken;
  }

  /// Backstop for every request path: platform sign-up and password reset
  /// never leave the client, whichever API reached them.
  static void _refuseConsoleOnly(String method, String path) {
    if (method.toUpperCase() != 'POST') return;
    var route = path.split('?').first;
    while (route.length > 1 && route.endsWith('/')) {
      route = route.substring(0, route.length - 1);
    }
    if (route == '/auth/signup') throw VaifConsoleOnlyError.signUp();
    if (route == '/auth/forgot-password') {
      throw VaifConsoleOnlyError.passwordReset();
    }
  }

  /// Sends a request as the signed-in user, if any.
  ///
  /// A 401 on a request that carried a session token triggers one refresh
  /// and one retry (see [_retryToken]): the API rejected the token before
  /// running the handler, so the replay cannot duplicate work.
  ///
  /// With [followSignedLink], an API answer that redirects to a signed
  /// object-store link is followed without the client's credentials, and
  /// the object store's response is returned.
  Future<http.Response> _send(
    String method,
    String path, {
    bool requireSession = false,
    Map<String, Object?>? query,
    Object? json,
    Object? body,
    Map<String, String>? headers,
    bool? idempotent,
    Duration? timeout,
    bool followSignedLink = false,
  }) async {
    _refuseConsoleOnly(method, path);
    final generation = auth._generation;
    final bearer = await auth._bearer();
    if (requireSession && bearer == null) {
      throw VaifAuthException('Not signed in', code: 'NOT_SIGNED_IN');
    }
    Future<http.Response> send(String? token) => _transport.request(
      method,
      path,
      query: query,
      json: json,
      body: body,
      headers: headers,
      bearer: token,
      idempotent: idempotent,
      timeout: timeout,
      allowRedirect: followSignedLink,
    );
    http.Response response;
    try {
      response = await send(bearer);
    } on VaifAuthException catch (error) {
      final token = await _retryToken(error, bearer, generation);
      if (token == null) rethrow;
      response = await send(token);
    }
    // Outside the 401 handling: an object-store refusal is not a rejected
    // session token.
    return followSignedLink ? _transport.followSignedLink(response) : response;
  }
}
