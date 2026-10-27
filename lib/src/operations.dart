import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'operation.dart';
import 'transport.dart';

/// The console's own sign-up and forgot-password: VAIF Studio accounts are
/// created and reset in the console only. These operations throw
/// [VaifConsoleOnlyError] before any request.
VaifConsoleOnlyError? consoleOnlyOperation(Operation operation) {
  if (operation.method != 'POST') return null;
  if (operation.path == '/auth/signup') {
    return VaifConsoleOnlyError.signUp(
      method: 'postAuthSignup()',
      ownApp: 'call postProjectsByProjectIdAuthSignup',
    );
  }
  if (operation.path == '/auth/forgot-password') {
    return VaifConsoleOnlyError.passwordReset(
      method: 'postAuthForgotPassword()',
      ownApp: 'call postProjectsByProjectIdAuthForgotPassword',
    );
  }
  return null;
}

/// Sends one request as the client's `_send` does.
typedef OperationSender =
    Future<http.Response> Function(
      String method,
      String path, {
      bool requireSession,
      Map<String, Object?>? query,
      Object? json,
      Object? body,
      Map<String, String>? headers,
      bool? idempotent,
      Duration? timeout,
      bool followSignedLink,
    });

/// Calls one generated operation; `Operations` methods go through it.
typedef OperationCaller =
    Future<Object?> Function(
      Operation operation, {
      Map<String, Object?>? path,
      Map<String, Object?>? query,
      Object? body,
      Map<String, String>? headers,
    });

/// Opens one streamed request as the client's `_stream` does.
typedef OperationStreamSender =
    Future<http.StreamedResponse> Function(
      String method,
      String path, {
      Map<String, Object?>? query,
      Object? json,
      Object? body,
      Map<String, String>? headers,
    });

/// The hand-written runtime behind the generated `Operations` methods.
class OperationsRuntime {
  /// Creates a runtime over the client's request sender and, for streamed
  /// operations, its stream sender.
  OperationsRuntime(this._send, {OperationStreamSender? stream})
    : _stream = stream;
  final OperationStreamSender? _stream;
  final OperationSender _send;

  /// Checks [operation]'s parameters, fills its path and sends it. Returns
  /// decoded JSON, the bytes of a binary response, or the live response of
  /// a streamed one.
  Future<Object?> call(
    Operation operation, {
    Map<String, Object?>? path,
    Map<String, Object?>? query,
    Object? body,
    Map<String, String>? headers,
  }) async {
    final consoleOnly = consoleOnlyOperation(operation);
    if (consoleOnly != null) throw consoleOnly;
    var url = operation.path;
    for (final name in operation.pathParams) {
      final value = path?[name];
      if (value == null || '$value'.isEmpty || value == '.' || value == '..') {
        throw ArgumentError('Missing or invalid path parameter: $name');
      }
      url = url.replaceAll('{$name}', Uri.encodeComponent('$value'));
    }
    for (final name in operation.requiredQuery) {
      if (query?[name] == null) {
        throw ArgumentError('Missing query parameter: $name');
      }
    }
    if (operation.bodyRequired && body == null) {
      throw ArgumentError('Missing request body');
    }
    final params = <String, Object?>{};
    void flatten(String key, Object? value) {
      if (value == null) return;
      if (value is Map<String, Object?>) {
        for (final entry in value.entries) {
          flatten('$key[${entry.key}]', entry.value);
        }
      } else if (value is List) {
        params[key] = value.where((e) => e != null).map((e) => '$e').toList();
      } else {
        params[key] = '$value';
      }
    }

    for (final entry in (query ?? <String, Object?>{}).entries) {
      flatten(entry.key, entry.value);
    }
    final requestHeaders = <String, String>{...?(headers)};
    if (operation.bodyKind == 'binary') {
      requestHeaders.putIfAbsent(
        'content-type',
        () => 'application/octet-stream',
      );
    }
    if (operation.bodyKind == 'text') {
      requestHeaders.putIfAbsent('content-type', () => 'text/plain');
    }
    // The API contract does not describe some request bodies, such as the
    // event-stream route's. An event-stream request with no declared body
    // kind sends the body as JSON; any other request sends no body unless
    // the contract declares its kind.
    if (operation.transport == 'sse' && _stream != null) {
      return _stream(
        operation.method,
        url,
        query: params,
        headers: requestHeaders,
        json:
            operation.bodyKind == 'json' || operation.bodyKind == null
                ? body
                : null,
        body:
            operation.bodyKind == 'binary' || operation.bodyKind == 'text'
                ? body
                : null,
      );
    }
    final response = await _send(
      operation.method,
      url,
      query: params,
      json: operation.bodyKind == 'json' ? body : null,
      body:
          operation.bodyKind == 'binary' || operation.bodyKind == 'text'
              ? body
              : null,
      headers: requestHeaders,
      // A binary read may be answered with a redirect to a signed link
      // (GET /storage/download always is); the bytes are read from there.
      followSignedLink: operation.transport == 'binary',
    );
    if (operation.transport == 'binary') return response.bodyBytes;
    if (operation.transport == 'sse') return response;
    return responseJson(response);
  }
}
