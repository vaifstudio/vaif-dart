import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaif_client/src/client.dart' show debugSetRetrySleep;
import 'package:vaif_client/vaif_client.dart';

const base = 'https://api.test.vaif';
const project = 'proj_123';
const key = 'vk_pub_test';

/// No waiting in unit tests: every retry delay collapses to zero.
const fastRetry = RetryPolicy(
  maxRetries: 3,
  baseDelay: Duration.zero,
  maxDelay: Duration.zero,
);

String dataPath(String table, [String suffix = '']) =>
    '/v1/data/$project/$table$suffix';
String authPath(String suffix) => '/projects/$project/auth/$suffix';

typedef Responder = FutureOr<http.Response> Function(http.Request request);

http.Response jsonResponse(
  int status,
  Object? body, {
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

/// A scripted API. Each route answers with its responses in order and then
/// keeps repeating the last one. A response is an [http.Response], a
/// [Responder], or an exception to throw.
class FakeApi {
  final List<http.Request> requests = [];
  final Map<String, List<Object>> _routes = {};

  void on(String method, String path, List<Object> responses) {
    _routes['$method $path'] = List.of(responses);
  }

  List<http.Request> calls(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final key = '${request.method} ${request.url.path}';
    final queue = _routes[key];
    if (queue == null || queue.isEmpty) {
      return jsonResponse(599, {
        'error': 'UNSCRIPTED',
        'message': 'no route for $key',
      });
    }
    final next = queue.length > 1 ? queue.removeAt(0) : queue.first;
    if (next is http.Response) return next;
    if (next is Responder) return next(request);
    if (next is Exception) throw next;
    throw StateError('bad scripted response: $next');
  }
}

/// A client wired to [api], with instant retries. [sleeps] records delays.
VaifClient makeClient(
  FakeApi api, {
  RetryPolicy retry = fastRetry,
  Duration timeout = const Duration(seconds: 5),
  List<Duration>? sleeps,
  Map<String, String>? headers,
}) {
  final client = VaifClient(
    projectId: project,
    apiKey: key,
    baseUrl: base,
    httpClient: api.client,
    retry: retry,
    timeout: timeout,
    headers: headers,
  );
  debugSetRetrySleep(client, (d) async => sleeps?.add(d));
  return client;
}

Map<String, dynamic> bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;
