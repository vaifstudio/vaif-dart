/// HTTP transport: headers, timeouts, bounded retries and error mapping.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show parseHttpDate;

import 'exceptions.dart';
import 'retry.dart';
import 'version.dart';

/// Header that carries the project API key.
const String apiKeyHeader = 'x-vaif-key';

const Set<String> _loopbackHosts = {'localhost', '127.0.0.1', '::1'};

/// True when [host] (as `Uri.host` returns it) may be reached without TLS:
/// plain http, and plain ws for realtime, only ever go to loopback hosts.
bool allowsCleartextHost(String host) => _loopbackHosts.contains(host);

/// Redirect statuses: the API answers a binary read with one to a signed
/// link, and an object store may answer a signed link with one.
const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

/// Redirects followed from one signed storage URL.
const int _maxSignedRedirects = 5;

/// Parses a signed object-store URL, from the API or from an object store's
/// redirect.
///
/// The URL carries a signature that grants access until it expires, so it
/// must use https, except for the loopback hosts a local stack uses. The
/// URL is not repeated in the exception, to keep the signature out of logs.
Uri signedStorageUri(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.host.isEmpty ||
      !(uri.scheme == 'https' ||
          (uri.scheme == 'http' && allowsCleartextHost(uri.host)))) {
    throw VaifException(
      'A signed storage URL does not use https',
      code: 'INSECURE_STORAGE_URL',
    );
  }
  return uri;
}

/// True when compiled for the web (dart2js / dart2wasm).
const bool _isWeb = bool.fromEnvironment('dart.library.js_interop');

/// Validates and normalizes the API base URL.
///
/// HTTPS is required so API keys and tokens never travel in cleartext. Plain
/// HTTP is accepted only for loopback hosts (local development).
String normalizeBaseUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (baseUrl.isEmpty ||
      uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'must be an absolute http(s) URL',
    );
  }
  if (uri.scheme == 'http' && !allowsCleartextHost(uri.host)) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'must use https (http is only allowed for localhost)',
    );
  }
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'must not have a query or fragment',
    );
  }
  var normalized = baseUrl;
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// Parses `Retry-After` (delta-seconds or an HTTP date).
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null || value.trim().isEmpty) return null;
  final text = value.trim();
  final seconds = double.tryParse(text);
  if (seconds != null) {
    if (!seconds.isFinite) return null;
    return Duration(milliseconds: (seconds < 0 ? 0 : seconds * 1000).round());
  }
  try {
    final when = parseHttpDate(text);
    final wait = when.difference(now ?? DateTime.now().toUtc());
    return wait.isNegative ? Duration.zero : wait;
  } on FormatException {
    return null;
  }
}

/// `toEncodable` for request JSON: DateTime becomes ISO-8601 UTC, anything
/// else must have a `toJson()` (the `jsonEncode` default).
Object? toJsonEncodable(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Uri) return value.toString();
  // ignore: avoid_dynamic_calls
  return (value as dynamic).toJson();
}

/// Decodes a body as JSON; falls back to text; null when empty.
Object? decodeBody(http.Response response) {
  if (response.bodyBytes.isEmpty) return null;
  final text = utf8.decode(response.bodyBytes, allowMalformed: true);
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

/// Decodes a successful JSON body, throwing [VaifException] for non-JSON.
Object? responseJson(http.Response response) {
  if (response.bodyBytes.isEmpty) return null;
  try {
    return jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    throw VaifException(
      'The API returned a non-JSON response',
      status: response.statusCode,
      body: text.length > 500 ? text.substring(0, 500) : text,
    );
  }
}

/// A decoded JSON object body, or an empty map.
Map<String, dynamic> responseObject(http.Response response) {
  final body = responseJson(response);
  return body is Map<String, dynamic> ? body : <String, dynamic>{};
}

/// Maps a non-2xx response to the matching [VaifException] subclass.
VaifException errorFromResponse(http.Response response) {
  final body = decodeBody(response);
  String? message;
  String? code;
  Object? details;
  String? requestId;
  if (body is Map<String, dynamic>) {
    final rawMessage = body['message'];
    final rawError = body['error'];
    final rawCode = body['code'];
    if (rawMessage is String && rawMessage.isNotEmpty) {
      message = rawMessage;
    } else if (rawError is String && rawError.isNotEmpty) {
      message = rawError;
    }
    if (rawCode is String && rawCode.isNotEmpty) {
      code = rawCode;
    } else if (rawError is String && rawError.isNotEmpty) {
      code = rawError;
    }
    details = body['details'];
    final rawRequestId = body['requestId'];
    if (rawRequestId is String) requestId = rawRequestId;
  } else if (body is String && body.isNotEmpty && body.length < 500) {
    message = body;
  }
  final status = response.statusCode;
  message ??= response.reasonPhrase ?? 'HTTP $status';
  requestId ??= response.headers['x-request-id'];
  if (status == 400 || status == 422) {
    return VaifValidationException(
      message,
      status: status,
      code: code,
      details: details,
      requestId: requestId,
      body: body,
      headers: response.headers,
    );
  }
  if (status == 401 || status == 403) {
    return VaifAuthException(
      message,
      status: status,
      code: code,
      details: details,
      requestId: requestId,
      body: body,
      headers: response.headers,
    );
  }
  if (status == 404) {
    return VaifNotFoundException(
      message,
      status: status,
      code: code,
      details: details,
      requestId: requestId,
      body: body,
      headers: response.headers,
    );
  }
  if (status == 409) {
    return VaifConflictException(
      message,
      status: status,
      code: code,
      details: details,
      requestId: requestId,
      body: body,
      headers: response.headers,
    );
  }
  if (status == 429) {
    return VaifRateLimitException(
      message,
      retryAfter: parseRetryAfter(response.headers['retry-after']),
      status: status,
      code: code,
      details: details,
      requestId: requestId,
      body: body,
      headers: response.headers,
    );
  }
  if (status >= 500) {
    return VaifServerException(
      message,
      status: status,
      code: code,
      details: details,
      requestId: requestId,
      body: body,
      headers: response.headers,
    );
  }
  return VaifException(
    message,
    status: status,
    code: code,
    details: details,
    requestId: requestId,
    body: body,
    headers: response.headers,
  );
}

class _AttemptTimeout implements Exception {
  const _AttemptTimeout();
}

/// An attempt that failed at the network level: a [http.ClientException],
/// or an error that `package:http` passes through as it is, such as a TLS
/// handshake failure or a socket error while the body is read.
class _NetworkFailure implements Exception {
  const _NetworkFailure(this.cause);
  final Exception cause;
  String get message {
    final cause = this.cause;
    return cause is http.ClientException ? cause.message : '$cause';
  }
}

/// Sends requests with the project key, timeouts and bounded retries.
class HttpTransport {
  /// Creates a transport. Throws [ArgumentError] for an invalid [baseUrl],
  /// an empty [apiKey] or a [timeout] that is not positive.
  HttpTransport({
    required String baseUrl,
    required String apiKey,
    required this.timeout,
    required this.retry,
    Map<String, String>? headers,
    http.Client? httpClient,
    Future<void> Function(Duration)? sleep,
  }) : baseUrl = normalizeBaseUrl(baseUrl),
       _apiKey = apiKey,
       _headers = Map.of(headers ?? const {}),
       _ownsClient = httpClient == null,
       _client = httpClient ?? http.Client(),
       sleep = sleep ?? ((d) => Future<void>.delayed(d)) {
    if (apiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'must not be empty');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  /// The normalized API origin.
  final String baseUrl;

  /// Bounds each attempt, including reading the response.
  final Duration timeout;

  /// How transient failures are retried.
  final RetryPolicy retry;
  final String _apiKey;
  final Map<String, String> _headers;
  final bool _ownsClient;
  final http.Client _client;

  /// Waits between retries. Tests replace it to record the delays.
  Future<void> Function(Duration delay) sleep;

  /// Closes the HTTP client if the transport created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, String> _buildHeaders(
    Map<String, String>? extra,
    String? bearer,
  ) {
    final headers = <String, String>{
      'accept': 'application/json',
      'accept-versions': 'v1',
      // Browsers own User-Agent, and a custom header would fail the API's
      // CORS preflight, so the SDK identifies itself on native only.
      if (!_isWeb) 'user-agent': 'vaif-dart/$packageVersion',
    };
    for (final entry in _headers.entries) {
      headers[entry.key.toLowerCase()] = entry.value;
    }
    if (extra != null) {
      for (final entry in extra.entries) {
        headers[entry.key.toLowerCase()] = entry.value;
      }
    }
    headers[apiKeyHeader] = _apiKey;
    if (bearer != null) headers['authorization'] = 'Bearer $bearer';
    return headers;
  }

  Uri _uri(String path, Map<String, Object?>? query) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  /// One attempt with a hard deadline covering the response body as well.
  Future<http.Response> _attempt(
    http.BaseRequest Function(Future<void> abort) build,
    Duration deadline,
  ) async {
    final abort = Completer<void>();
    final request = build(abort.future);
    try {
      return await () async {
        final streamed = await _client.send(request);
        return http.Response.fromStream(streamed);
      }().timeout(
        deadline,
        onTimeout: () {
          // Cancels the in-flight request on clients that support aborting.
          if (!abort.isCompleted) abort.complete();
          throw const _AttemptTimeout();
        },
      );
    } on http.RequestAbortedException {
      throw const _AttemptTimeout();
    } on _AttemptTimeout {
      rethrow;
    } on VaifException {
      rethrow;
    } on Exception catch (error) {
      throw _NetworkFailure(error);
    }
  }

  /// Sends a request and returns the successful (2xx) response.
  ///
  /// Throws a [VaifException] subclass for non-2xx responses, timeouts and
  /// network failures once the retry budget is spent. Redirects are never
  /// followed, because a followed redirect would carry the API key to another
  /// host. With [allowRedirect], a redirect that has a `Location` header is
  /// returned instead of thrown; pass it to [followSignedLink].
  Future<http.Response> request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? json,
    Object? body,
    Map<String, String>? headers,
    String? bearer,
    bool? idempotent,
    Duration? timeout,
    RetryPolicy? retry,
    bool allowRedirect = false,
  }) async {
    final verb = method.toUpperCase();
    final policy = retry ?? this.retry;
    final replaySafe = idempotent ?? replaySafeMethods.contains(verb);
    final uri = _uri(path, query);
    final requestHeaders = _buildHeaders(headers, bearer);
    List<int>? bytes;
    if (body != null) {
      if (body is String) {
        bytes = utf8.encode(body);
      } else if (body is List<int>) {
        bytes = body;
      } else {
        throw ArgumentError.value(body, 'body', 'must be text or bytes');
      }
    }
    if (json != null) {
      bytes = utf8.encode(jsonEncode(json, toEncodable: toJsonEncodable));
      requestHeaders['content-type'] = 'application/json';
    }
    final deadline = timeout ?? this.timeout;
    var attempt = 0;
    while (true) {
      final http.Response response;
      try {
        response = await _attempt((abort) {
          final request = http.AbortableRequest(verb, uri, abortTrigger: abort);
          request.followRedirects = false;
          request.headers.addAll(requestHeaders);
          if (bytes != null) request.bodyBytes = bytes;
          return request;
        }, deadline);
      } on _AttemptTimeout {
        if (replaySafe &&
            policy.retryOnNetworkError &&
            attempt < policy.budget) {
          await sleep(policy.delayFor(attempt));
          attempt++;
          continue;
        }
        throw VaifTimeoutException(
          'Request timed out after ${deadline.inMilliseconds} ms',
        );
      } on _NetworkFailure catch (failure) {
        if (replaySafe &&
            policy.retryOnNetworkError &&
            attempt < policy.budget) {
          await sleep(policy.delayFor(attempt));
          attempt++;
          continue;
        }
        throw VaifNetworkException(
          'Network error: ${failure.message}',
          cause: failure.cause,
        );
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }
      if (allowRedirect &&
          _redirectStatuses.contains(response.statusCode) &&
          response.headers['location'] != null) {
        return response;
      }
      final error = errorFromResponse(response);
      if (replaySafe &&
          policy.retryOn.contains(response.statusCode) &&
          attempt < policy.budget) {
        final retryAfter =
            error is VaifRateLimitException ? error.retryAfter : null;
        await sleep(policy.delayFor(attempt, retryAfter: retryAfter));
        attempt++;
        continue;
      }
      throw error;
    }
  }

  /// Opens a live response. The timeout covers response headers; callers own
  /// stream cancellation and any overall stream deadline. Streaming writes are
  /// never automatically replayed after a network failure. A failure while
  /// the body streams arrives on the body stream as a [VaifNetworkException]
  /// whose `cause` is the transport's error.
  Future<http.StreamedResponse> requestStream(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? json,
    Object? body,
    Map<String, String>? headers,
    String? bearer,
  }) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      _uri(path, query),
      abortTrigger: abort.future,
    );
    request.followRedirects = false;
    request.headers.addAll(_buildHeaders(headers, bearer));
    if (json != null) {
      request.bodyBytes = utf8.encode(
        jsonEncode(json, toEncodable: toJsonEncodable),
      );
      request.headers['content-type'] = 'application/json';
    } else if (body is String) {
      request.body = body;
    } else if (body is List<int>) {
      request.bodyBytes = body;
    } else if (body != null) {
      throw ArgumentError('Stream body must be text or bytes');
    }
    try {
      final response = await _client
          .send(request)
          .timeout(
            timeout,
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw VaifTimeoutException('Stream response headers timed out');
            },
          );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _typedErrors(response);
      }
      throw errorFromResponse(
        await http.Response.fromStream(response).timeout(timeout),
      );
    } on VaifException {
      rethrow;
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw VaifTimeoutException('Stream error response timed out');
    } on Exception catch (error) {
      // A ClientException, or a dart:io error package:http passes through.
      throw VaifNetworkException('Stream connection failed', cause: error);
    }
  }

  /// [response] with a body stream whose errors are [VaifException]s.
  static http.StreamedResponse _typedErrors(http.StreamedResponse response) =>
      http.StreamedResponse(
        response.stream.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleError: (error, stackTrace, sink) {
              sink.addError(
                error is VaifException
                    ? error
                    : VaifNetworkException(
                      'The response stream failed',
                      cause: error,
                    ),
                stackTrace,
              );
            },
          ),
        ),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );

  /// Sends one request to a signed object-store URL, retrying transient
  /// failures, and returns the last response, whatever its status.
  ///
  /// The URL points at the object store, not the VAIF API, so none of the
  /// client's headers (API key, bearer token) are sent. Requests to the same
  /// signed URL are idempotent, so timeouts, network errors and the policy's
  /// retry statuses are retried as for a GET.
  ///
  /// A read follows the object store's redirects, up to five, and only to
  /// URLs that [signedStorageUri] accepts. In a browser, which does not show
  /// redirects to the page, the browser follows them and refuses https to
  /// http itself.
  Future<http.Response> _sendSigned(
    String method,
    Uri uri, {
    required String action,
    List<int>? bytes,
    String? contentType,
  }) async {
    final policy = retry;
    final followHere = !_isWeb && method == 'GET';
    var target = uri;
    var redirects = 0;
    var attempt = 0;
    while (true) {
      final http.Response response;
      try {
        response = await _attempt((abort) {
          final request = http.AbortableRequest(
            method,
            target,
            abortTrigger: abort,
          );
          request.followRedirects = _isWeb && method == 'GET';
          if (contentType != null) {
            request.headers['content-type'] = contentType;
          }
          if (bytes != null) request.bodyBytes = bytes;
          return request;
        }, timeout);
      } on _AttemptTimeout {
        if (policy.retryOnNetworkError && attempt < policy.budget) {
          await sleep(policy.delayFor(attempt));
          attempt++;
          continue;
        }
        throw VaifTimeoutException('Timed out $action storage');
      } on _NetworkFailure catch (failure) {
        if (policy.retryOnNetworkError && attempt < policy.budget) {
          await sleep(policy.delayFor(attempt));
          attempt++;
          continue;
        }
        throw VaifNetworkException(
          'Network error $action storage: ${failure.message}',
          cause: _withoutQuery(failure.cause),
        );
      }
      final location = response.headers['location'];
      if (followHere &&
          _redirectStatuses.contains(response.statusCode) &&
          location != null &&
          redirects < _maxSignedRedirects) {
        target = signedStorageUri(target.resolve(location).toString());
        redirects++;
        continue;
      }
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (!ok &&
          policy.retryOn.contains(response.statusCode) &&
          attempt < policy.budget) {
        await sleep(policy.delayFor(attempt));
        attempt++;
        continue;
      }
      return response;
    }
  }

  /// [cause] with the query removed from its URL.
  ///
  /// The query of a signed storage URL is the credential that grants access
  /// to the object, and a [http.ClientException] prints its URL in full.
  /// Applications log errors and their causes, so a [http.ClientException]
  /// is replaced by one with the same message and the URL without its user
  /// info, query or fragment. Other causes, such as a TLS or socket error
  /// from `dart:io`, are returned unchanged.
  static Exception _withoutQuery(Exception cause) {
    if (cause is! http.ClientException) return cause;
    final uri = cause.uri;
    if (uri == null) return cause;
    return http.ClientException(
      cause.message,
      Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      ),
    );
  }

  /// PUTs bytes to a presigned storage URL.
  ///
  /// Sends none of the client's headers. Throws `INSECURE_STORAGE_URL` before
  /// any request when the URL is not https (http only for loopback hosts),
  /// and `STORAGE_UPLOAD_FAILED` when the object store refuses the upload.
  Future<void> putPresigned(
    String url,
    List<int> bytes,
    String contentType,
  ) async {
    final response = await _sendSigned(
      'PUT',
      signedStorageUri(url),
      action: 'uploading to',
      bytes: bytes,
      contentType: contentType,
    );
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final error = errorFromResponse(response);
    throw VaifException(
      error.message,
      status: error.status,
      code: error.code ?? 'STORAGE_UPLOAD_FAILED',
      requestId: error.requestId,
      body: error.body,
      headers: error.headers,
    );
  }

  /// GETs the bytes at a signed storage URL.
  ///
  /// Sends none of the client's headers. Throws `INSECURE_STORAGE_URL` before
  /// any request when the URL is not https (http only for loopback hosts). A
  /// non-2xx answer from the object store is mapped like an API error, so a
  /// missing object (404) is a [VaifNotFoundException].
  Future<http.Response> getPresigned(String url) async {
    final response = await _sendSigned(
      'GET',
      signedStorageUri(url),
      action: 'downloading from',
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw errorFromResponse(response);
  }

  /// Reads the bytes behind an API response that redirects to a signed link
  /// (see `allowRedirect` on [request]); any other response is returned
  /// unchanged. A relative `Location` is resolved against the request URL.
  Future<http.Response> followSignedLink(http.Response response) async {
    final location = response.headers['location'];
    if (!_redirectStatuses.contains(response.statusCode) || location == null) {
      return response;
    }
    final from = response.request?.url ?? Uri.parse(baseUrl);
    return getPresigned(from.resolve(location).toString());
  }
}
