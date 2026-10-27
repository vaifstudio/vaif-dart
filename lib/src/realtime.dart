/// Pure Dart WebSocket database subscriptions, usable from Flutter and the web.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'exceptions.dart';
import 'transport.dart' show allowsCleartextHost;

final RegExp _realtimeIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Operators a realtime row filter supports: the ones the server's channel
/// parser accepts.
const Set<String> realtimeFilterOperators = {
  'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', //
};

/// One server-side row filter on a table subscription, e.g.
/// `RealtimeFilter('status', 'eq', 'open')` or
/// `RealtimeFilter('tag', 'in', ['a', 'b'])`. Values are strings, numbers or
/// booleans (`in` takes a list of them); the server compares them as text
/// (`eq`, `neq`, `in`) or numbers (`gt`, `gte`, `lt`, `lte`).
class RealtimeFilter {
  /// Creates a filter: [field] compared with [operator] to [value].
  const RealtimeFilter(this.field, this.operator, this.value);

  /// The column to compare.
  final String field;

  /// One of [realtimeFilterOperators].
  final String operator;

  /// The value to compare with; a list for `in`.
  final Object? value;

  static String _scalar(String field, Object? value) {
    if (value is String) return value;
    if (value is num || value is bool) return '$value';
    throw ArgumentError.value(
      value,
      field,
      'realtime filters compare strings, numbers and booleans',
    );
  }

  /// `field.op=value`, as the server's channel parser reads it.
  String _encode() {
    if (!_realtimeIdentifier.hasMatch(field)) {
      throw ArgumentError.value(field, 'field', 'must be a column name');
    }
    if (!realtimeFilterOperators.contains(operator)) {
      throw ArgumentError.value(
        operator,
        'operator',
        'realtime filters support ${realtimeFilterOperators.join('/')}',
      );
    }
    final String text;
    if (operator == 'in') {
      final values = value;
      if (values is! List || values.isEmpty) {
        throw ArgumentError.value(value, field, "'in' needs a non-empty list");
      }
      final parts = [for (final v in values) _scalar(field, v)];
      if (parts.any((p) => p.contains(','))) {
        throw ArgumentError.value(
          value,
          field,
          "'in' values cannot contain ','",
        );
      }
      text = parts.join(',');
    } else {
      text = _scalar(field, value);
    }
    return '$field.$operator=${Uri.encodeComponent(text)}';
  }
}

/// The server channel for a table subscription:
/// `table:<table>[?<field>.<op>=<value>&...&columns=a,b]`.
String buildTableChannel(
  String table, {
  List<RealtimeFilter> filters = const [],
  List<String>? columns,
}) {
  if (!_realtimeIdentifier.hasMatch(table)) {
    throw ArgumentError.value(table, 'table', 'must be a SQL identifier');
  }
  final parts = [for (final f in filters) f._encode()];
  if (columns != null && columns.isNotEmpty) {
    for (final c in columns) {
      if (!_realtimeIdentifier.hasMatch(c)) {
        throw ArgumentError.value(c, 'columns', 'must be column names');
      }
    }
    parts.add('columns=${columns.join(',')}');
  }
  return parts.isEmpty ? 'table:$table' : 'table:$table?${parts.join('&')}';
}

/// A table subscription acknowledged by the server.
class RealtimeSubscription {
  RealtimeSubscription._(
    this._client,
    this.table,
    this.channel, {
    required bool filtered,
  }) : _filtered = filtered;
  final RealtimeClient _client;
  final bool _filtered;

  /// The table this subscription watches.
  final String table;

  /// The server channel, including any filters and columns.
  final String channel;
  final _ready = Completer<void>();
  final _changes = StreamController<Map<String, dynamic>>.broadcast();

  /// VAIF db_change frames: op, record, old_record, table, schema and ts.
  Stream<Map<String, dynamic>> get changes => _changes.stream;

  /// Stops the subscription and closes [changes]. Safe to call repeatedly.
  Future<void> unsubscribe() async {
    if (!identical(_client._subscriptions[channel], this)) return;
    _client._subscriptions.remove(channel);
    _client._send({'type': 'unsubscribe', 'channel': channel});
    if (!_ready.isCompleted) {
      _ready.completeError(
        VaifException('Subscription canceled', code: 'CLOSED'),
      );
    }
    unawaited(_changes.close());
  }
}

/// Database change subscriptions over one WebSocket (`/realtime/ws`).
///
/// The connection authenticates with its first frame, so credentials never
/// appear in the URL. [subscribe] waits for the server's welcome and its
/// acknowledgment. When the connection drops, every subscription reports a
/// [VaifException] and closes; subscribe again to reconnect. Use
/// `VaifClient.realtime`, which follows the client's session.
class RealtimeClient {
  /// Creates a client for the API at [baseUrl], authenticating with
  /// [apiKey] and the token [accessToken] returns (null for none).
  /// [timeout] bounds the connection, the welcome and each subscription.
  /// [channelFactory] replaces `WebSocketChannel.connect`. Throws
  /// `INVALID_REALTIME_URL` for a base URL that is not https, other than
  /// http on a loopback host.
  RealtimeClient({
    required String baseUrl,
    required String apiKey,
    required Future<String?> Function() accessToken,
    required this.timeout,
    WebSocketChannel Function(Uri)? channelFactory,
  }) : _uri = _socketUri(baseUrl),
       _apiKey = apiKey,
       _accessToken = accessToken,
       _channelFactory = channelFactory ?? WebSocketChannel.connect;

  /// The socket URL for [baseUrl]: https becomes wss, and http becomes ws only
  /// for the hosts the HTTP client also reaches without TLS (localhost,
  /// 127.0.0.1, ::1). Anything else throws `INVALID_REALTIME_URL`, so the
  /// first frame, which carries the API key and access token, never travels
  /// unencrypted. Runs in the constructor, before any token is read or
  /// socket opened.
  static Uri _socketUri(String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    final scheme = base?.scheme.toLowerCase();
    if (base == null || base.host.isEmpty) {
      throw _invalidRealtimeUrl('baseUrl must be an absolute https URL');
    }
    final String socketScheme;
    if (scheme == 'https') {
      socketScheme = 'wss';
    } else if (scheme == 'http' && allowsCleartextHost(base.host)) {
      socketScheme = 'ws';
    } else {
      throw _invalidRealtimeUrl(
        'realtime needs an https baseUrl (http only for localhost, '
        '127.0.0.1 or ::1)',
      );
    }
    return Uri.parse('$baseUrl/realtime/ws').replace(scheme: socketScheme);
  }

  static VaifValidationException _invalidRealtimeUrl(String message) =>
      VaifValidationException(message, code: 'INVALID_REALTIME_URL');

  final WebSocketChannel Function(Uri) _channelFactory;
  final Uri _uri;
  final String _apiKey;
  final Future<String?> Function() _accessToken;

  /// Bounds the connection, the welcome and each subscription.
  final Duration timeout;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _listener;
  Timer? _heartbeat;
  Completer<void>? _welcome;
  Future<void>? _connecting;
  bool _connected = false;
  bool _awaitingPong = false;
  final Map<String, RealtimeSubscription> _subscriptions = {};

  /// The access token the handshake's auth frame carried.
  String? _handshakeToken;

  /// A token set by [setAuth] while the handshake was in progress, sent
  /// once the server welcomes the connection.
  String? _pendingToken;

  /// Whether the server has welcomed the connection and it is still open.
  bool get isConnected => _connected;

  /// Opens and authenticates the connection, if it is not open already.
  ///
  /// [subscribe] calls this itself. Completes when the server welcomes the
  /// connection; throws a [VaifException] when it cannot be opened, the
  /// server refuses it, or no welcome arrives within the timeout.
  Future<void> connect() {
    if (_connected) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    final WebSocketChannel socket;
    try {
      socket = _channelFactory(_uri);
    } catch (error) {
      throw VaifNetworkException('Realtime connection failed', cause: error);
    }
    final welcome = Completer<void>();
    _welcome = welcome;
    // Attach an error handler before any await to avoid uncaught handshake errors.
    final welcomed = welcome.future.timeout(timeout);
    _socket = socket;
    _handshakeToken = null;
    _pendingToken = null;
    _listener = socket.stream.listen(
      (dynamic data) {
        if (!identical(socket, _socket)) return;
        // The protocol is JSON text; binary and malformed frames are not
        // part of it and are ignored.
        if (data is! String) return;
        try {
          final message = jsonDecode(data);
          if (message is Map<String, dynamic>) _message(message);
        } on FormatException {
          // Not JSON.
        }
      },
      onError: (Object error) {
        if (identical(socket, _socket)) {
          _fail(
            VaifNetworkException('Realtime connection failed', cause: error),
          );
        }
      },
      onDone: () {
        if (identical(socket, _socket)) {
          _fail(VaifNetworkException('Realtime connection closed'));
        }
      },
    );
    unawaited(() async {
      try {
        await socket.ready.timeout(timeout);
        final token = await _accessToken();
        if (!identical(socket, _socket)) return;
        _handshakeToken = token;
        _send({
          'type': 'auth',
          'apiKey': _apiKey,
          if (token != null) 'accessToken': token,
        });
      } catch (error) {
        if (identical(socket, _socket)) {
          // A VaifException (a failed token refresh) is reported as it is.
          _fail(
            error is VaifException
                ? error
                : VaifNetworkException(
                  'Realtime handshake failed',
                  cause: error,
                ),
          );
        }
      }
    }());
    try {
      await welcomed;
    } on TimeoutException {
      final error = VaifTimeoutException('Realtime welcome timed out');
      _fail(error);
      throw error;
    }
  }

  /// Subscribes to INSERT, UPDATE and DELETE events on [table], optionally
  /// narrowed by server-side [filters] (ANDed) and limited to [columns].
  ///
  /// Completes once the server acknowledges the subscription. One
  /// subscription per channel: share its [RealtimeSubscription.changes]
  /// stream across listeners; subscribing to the same channel twice throws
  /// [StateError].
  Future<RealtimeSubscription> subscribe(
    String table, {
    List<RealtimeFilter> filters = const [],
    List<String>? columns,
  }) async {
    final channel = buildTableChannel(
      table,
      filters: filters,
      columns: columns,
    );
    await connect();
    if (_subscriptions.containsKey(channel)) {
      throw StateError('Already subscribed to $channel');
    }
    final sub = RealtimeSubscription._(
      this,
      table,
      channel,
      filtered: filters.isNotEmpty,
    );
    _subscriptions[channel] = sub;
    _send({'type': 'subscribe', 'channel': channel});
    try {
      await sub._ready.future.timeout(timeout);
    } on TimeoutException {
      await sub.unsubscribe();
      throw VaifTimeoutException('Realtime subscription timed out');
    }
    return sub;
  }

  void _send(Map<String, Object?> frame) =>
      _socket?.sink.add(jsonEncode(frame));

  /// Sends a new access token on the open connection, for example after a
  /// token refresh; null (signed out) closes the connection.
  ///
  /// During the handshake, the token is sent once the server welcomes the
  /// connection, unless the handshake already carried it.
  void setAuth(String? token) {
    if (token == null) {
      disconnect();
      return;
    }
    if (_connected) {
      _send({'type': 'auth', 'accessToken': token});
    } else if (_socket != null) {
      _pendingToken = token;
    }
  }

  void _message(Map<String, dynamic> message) {
    _awaitingPong = false;
    switch (message['type']) {
      case 'welcome':
        _connected = true;
        final pending = _pendingToken;
        _pendingToken = null;
        if (pending != null && pending != _handshakeToken) {
          _send({'type': 'auth', 'accessToken': pending});
        }
        if (!(_welcome?.isCompleted ?? true)) _welcome!.complete();
        _heartbeat?.cancel();
        _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
          if (_awaitingPong) {
            _fail(VaifTimeoutException('Realtime heartbeat timed out'));
            return;
          }
          _awaitingPong = true;
          _send({'type': 'ping'});
        });
      case 'subscribed':
        final sub = _subscriptions[message['channel']];
        if (sub != null && !sub._ready.isCompleted) sub._ready.complete();
      case 'db_change':
        // The server names every matching channel in `channels`; `channel`
        // is only the first of them. A server without either is answered
        // for unfiltered subscriptions only, never guessed for filtered ones.
        final targets = message['channels'];
        final single = message['channel'];
        for (final sub in _subscriptions.values.toList()) {
          if (message['table'] != sub.table) continue;
          final bool match;
          if (targets is List) {
            match = targets.contains(sub.channel);
          } else if (single is String) {
            match = single == sub.channel;
          } else {
            match = !sub._filtered;
          }
          if (match && !sub._changes.isClosed) sub._changes.add(message);
        }
      case 'error':
        final rawMessage = message['message'];
        final rawCode = message['code'] ?? message['error'];
        final error = VaifException(
          rawMessage is String ? rawMessage : 'Realtime refused the request',
          code: rawCode is String ? rawCode : null,
        );
        final sub = _subscriptions[message['channel']];
        if (sub != null && !sub._ready.isCompleted) {
          sub._ready.completeError(error);
          _subscriptions.remove(sub.channel);
          unawaited(sub._changes.close());
        } else if (!_connected || message['closeCode'] != null) {
          // A refused handshake, or an error the server closes the socket
          // after (auth refresh failed, session ended).
          _fail(error);
        }
      // Anything else (rate limited, an unparseable frame) leaves the
      // connection and its subscriptions running, as on the server.
    }
  }

  void _fail(VaifException error) {
    if (!(_welcome?.isCompleted ?? true)) _welcome!.completeError(error);
    for (final sub in _subscriptions.values) {
      if (!sub._ready.isCompleted) {
        sub._ready.completeError(error);
      } else if (sub._changes.hasListener) {
        sub._changes.addError(error);
      }
      unawaited(sub._changes.close());
    }
    _subscriptions.clear();
    _connected = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    _handshakeToken = null;
    _pendingToken = null;
    final socket = _socket;
    _socket = null;
    _listener?.cancel().ignore();
    _listener = null;
    // A socket that failed to open can fail its close too; that is not news.
    socket?.sink.close().ignore();
  }

  /// Closes the socket and all subscriptions. Safe to call repeatedly.
  void disconnect() =>
      _fail(VaifException('Realtime disconnected', code: 'CLOSED'));
}
