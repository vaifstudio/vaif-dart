part of 'client.dart';

const Set<String> _functionMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};

/// Calls the project's functions by name or id (`POST /functions/:name/invoke`).
class FunctionsClient {
  FunctionsClient._(this._client);

  final VaifClient _client;

  /// Invokes a function and returns its HTTP response.
  ///
  /// [method], [path], [query] and [headers] are what the function itself
  /// sees. Non-2xx responses throw the matching [VaifException] subclass with
  /// the function's body in `body`. Invocations are not retried unless
  /// [idempotent] is true.
  Future<FunctionResponse> invoke(
    String name, {
    Object? body,
    String method = 'POST',
    String path = '/',
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool idempotent = false,
  }) async {
    final segment = _pathSegment(name, 'name');
    final verb = method.toUpperCase();
    if (!_functionMethods.contains(verb)) {
      throw ArgumentError.value(
        method,
        'method',
        'must be one of $_functionMethods',
      );
    }
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', "must start with '/'");
    }
    // Always the envelope form: a raw body that happened to contain a
    // "method" or "path" key would otherwise be misread as an envelope.
    final envelope = <String, Object?>{
      'method': verb,
      'path': path,
      if (query != null && query.isNotEmpty) 'query': query,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
      if (body != null) 'body': body,
    };
    final response = await _client._send(
      'POST',
      '/functions/$segment/invoke',
      json: envelope,
      timeout: timeout,
      idempotent: idempotent,
    );
    final contentType = response.headers['content-type'] ?? '';
    Object? data;
    if (response.bodyBytes.isEmpty) {
      data = null;
    } else if (contentType.contains('json')) {
      data = decodeBody(response);
    } else if (contentType.startsWith('text/')) {
      data = utf8.decode(response.bodyBytes, allowMalformed: true);
    } else {
      data = response.bodyBytes;
    }
    return FunctionResponse(
      status: response.statusCode,
      headers: response.headers,
      data: data,
    );
  }
}
